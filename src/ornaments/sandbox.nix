{ mb, fx, api, pkgs, lib, ... }:

let
  compileSeccomp = import ./sandbox-helpers/compile-seccomp.nix { inherit pkgs lib; };
  combinators = import ./sandbox-helpers/combinators.nix { inherit lib mb; };

  inherit (mb.operations)
    sandboxProfile tcpEndpoint displayConfig dnsConfig
    seccompStages lifecycles;

  define = sandboxProfile;

  # Generic public profiles. `sealed` is the empty default (no network,
  # no exec, /nix/store read-only, /tmp tmpfs). `effectful` adds execve
  # and fork. Anything more specific is composed by consumers — either
  # via combinators or via downstream profile additions.
  profiles = {
    sealed = sandboxProfile { };
    effectful = sandboxProfile { allowExecve = true; allowFork = true; };
  };

  # ============================================================================
  # Backend eliminators
  # ============================================================================

  # toBwrap : SandboxProfile -> [String]
  #
  # Generic bubblewrap arg list. No host-specific DNS/NSS configuration
  # is embedded — values come through `profile.dns` (an `H.maybe
  # DnsConfig`) when the consumer supplies them. The eliminator emits
  # only the mounts/namespaces/stdio handling that bwrap is responsible
  # for; TCP port enforcement is a Landlock/iptables concern and lives
  # in `LandlockProfile` output.
  toBwrap = profile:
    let
      roBinds = lib.concatMap (p: [ "--ro-bind" p p ]) profile.readOnlyPaths;
      rwBinds = lib.concatMap (p: [ "--bind" p p ]) profile.readWritePaths;
      tmpfsMounts = lib.concatMap (p: [ "--tmpfs" p ]) profile.tmpfs;
      socketBinds = lib.concatMap (p: [ "--bind" p p ]) profile.unixSockets;
      devBinds = [ "--dev" "/dev" "--proc" "/proc" ];
      namespaces =
        lib.optionals (!profile.daemonMode) [ "--unshare-pid" ]
        ++ [ "--new-session" ]
        ++ lib.optionals (!profile.daemonMode) [ "--die-with-parent" ];
      stdioArgs = lib.optionals (!profile.stdio) [
        "--dev-bind"
        "/dev/null"
        "/dev/stdin"
        "--dev-bind"
        "/dev/null"
        "/dev/stdout"
        "--dev-bind"
        "/dev/null"
        "/dev/stderr"
      ];
      dnsBinds =
        if profile.dns == null then [ ]
        else
          let
            d = profile.dns;
            resolvPath = toString (fx.state.forceThunk d.resolv);
            nsswitchPath = toString (fx.state.forceThunk d.nsswitch);
          in
          [
            "--ro-bind"
            resolvPath
            "/etc/resolv.conf"
            "--ro-bind"
            nsswitchPath
            "/etc/nsswitch.conf"
          ] ++ d.extraBinds;
    in
    roBinds ++ rwBinds ++ tmpfsMounts ++ socketBinds
    ++ devBinds ++ dnsBinds ++ namespaces ++ stdioArgs;

  # toLandlock : SandboxProfile -> LandlockProfile
  # Landlock does not differentiate bind-mounted rw paths from tmpfs
  # mount points — both are writable from the application's perspective
  # and both must be in the writable set for Landlock's deny-by-default
  # policy to permit writes. The eliminator flattens the two source
  # fields accordingly; `toBwrap` continues to keep them distinct
  # because bwrap performs different mount operations.
  toLandlock = profile: {
    _con = "MetaBuilderLandlockProfile";
    inherit (profile) readOnlyPaths allowExecve connectAny;
    readWritePaths = profile.readWritePaths ++ profile.tmpfs;
    listenPorts = map (e: e.port) profile.listenTcp;
    connectPorts = map (e: e.port) profile.connectTcp;
  };

  # toSeccomp : SandboxProfile -> SeccompStage -> Thunk Derivation
  #
  # Stage `Bwrap` includes processExec (bwrap needs execve to launch
  # the child). Stage `Self` includes processExec only when the profile
  # is `effectful` (i.e. `allowExecve == true`).
  # Exec syscalls only when the stage launches children: Bwrap always, Self iff effectful.
  seccompCategoriesFor = profile: stage:
    let
      baseCategories = with compileSeccomp.syscallSets; [
        memory
        fileIo
        network
        signals
        threading
        processInfo
        time
        ipc
        fileManagement
        landlock
        seccompSelf
      ];
      withExec = baseCategories ++ [ compileSeccomp.syscallSets.processExec ];
    in
    if stage._con == "Bwrap" then withExec
    else if profile.allowExecve then withExec
    else baseCategories;

  toSeccomp = profile: stage:
    let
      stageTag = if stage._con == "Bwrap" then "bwrap" else "self";
      execTag = if profile.allowExecve then "effectful" else "sealed";
      name = "seccomp-${stageTag}-${execTag}";
    in
    fx.state.mkThunk (compileSeccomp.mkFilter {
      categories = seccompCategoriesFor profile stage;
      inherit name;
    });

  # toSystemd : SandboxProfile -> SystemdHardening
  toSystemd = profile: {
    _con = "MetaBuilderSystemdHardening";
    protectSystem = "strict";
    protectHome = true;
    privateTmp = true;
    noNewPrivileges = true;
    readOnlyPaths = profile.readOnlyPaths;
    readWritePaths = profile.readWritePaths;
    systemCallFilter =
      if profile.allowExecve
      then [ "@system-service" ]
      else [ "@system-service" "~@privileged" "~execve" "~execveat" ];
    restrictNamespaces = true;
    privateDevices = true;
  };

  value = {
    inherit define profiles combinators;
    inherit toBwrap toLandlock toSeccomp toSystemd seccompCategoriesFor;
    inherit (compileSeccomp) syscallSets mkFilter mkAllowlist flattenPolicy generator;
    SeccompStage = seccompStages;
    Lifecycle = lifecycles;
    tcpEndpoint = tcpEndpoint;
    displayConfig = displayConfig;
    dnsConfig = dnsConfig;
  };

in
api.mk {
  description = "sandbox ornament: typed sandbox profile over the bwrap/Landlock/seccomp/systemd backends. Four eliminators (toBwrap/toLandlock/toSeccomp/toSystemd) consume the same `SandboxProfile` and emit backend-specific configuration. Public profiles: `sealed`, `effectful` — anything host- or workload-specific composes downstream.";
  doc = ''
    # Sandbox

    Typed declarative sandbox profile. The profile is the single source
    of truth; four enforcement backends — bubblewrap, Landlock, seccomp
    BPF, and systemd hardening — consume the same declaration and
    produce backend-specific configuration.

    Three-layer defense:
      1. **bwrap**: mount namespace, PID namespace, seccomp stage-1.
      2. **Landlock**: path-based filesystem access (applied from inside
         the process post-init).
      3. **seccomp stage-2**: self-applied filter blocking `execve`
         post-init when the profile is sealed.

    - **Smart constructor** `sandbox.define { readOnlyPaths?;
      readWritePaths?; tmpfs?; listenTcp?; connectTcp?; display?;
      stdio?; unixSockets?; allowExecve?; allowFork?; lifecycle?;
      daemonMode?; dns?; sourceAccess?; sourceWritePaths?;
      coordinationWritePaths?; storeAccess?; }` proxies to
      `mb.operations.sandboxProfile` (eager structural validation
      against `SandboxProfile.T`).

    - **Built-in profiles** as typed `SandboxProfile` values:
      `profiles.sealed` (the empty default), `profiles.effectful`
      (sealed + execve + fork). Anything host- or workload-specific
      composes downstream.

    - **Eliminators**:
      - `toBwrap : SandboxProfile → [String]` — bubblewrap argument
        list. DNS handling routes through `profile.dns` when present.
      - `toLandlock : SandboxProfile → LandlockProfile` — path-list +
        port-list view.
      - `toSeccomp : SandboxProfile → SeccompStage → Thunk Derivation` —
        BPF filter; stage `Bwrap` includes `processExec`, stage `Self`
        respects `allowExecve`.
      - `toSystemd : SandboxProfile → SystemdHardening` — directives
        suitable for `systemd.services.<name>.serviceConfig`.

    - **Closed-sum re-exports**: `SeccompStage = Bwrap | Self`,
      `Lifecycle = LongRunning | OneShot`.

    - **Combinators** in `sandbox.combinators`: `compose`, base
      profiles (`sealed`/`effectful`), network (`listen`/`connectTo`),
      filesystem (`readonly`/`readwrite`), execution
      (`allowExec`/`allowFork`), lifecycle (`daemon`), and a `defer`
      meta-combinator for two-pass composition. Each carries `{ sig;
      doc; impl }` metadata.

    - **Seccomp compiler**: `syscallSets` exposes 12 generic syscall
      categories. `mkFilter`/`mkAllowlist`/`flattenPolicy` compose them
      into BPF filters via the bundled `gen-seccomp-bpf` tool. The
      compiler is a standalone C program (single source file) that
      reads a newline-separated allowlist and emits a BPF blob.
  '';
  inherit value;
  tests =
    let
      sealedP = profiles.sealed;
      effectfulP = profiles.effectful;
    in
    {
      "profile-sealed-typed-shape" = {
        expr = sealedP._con;
        expected = "MetaBuilderSandboxProfile";
      };

      "profile-sealed-defaults-no-exec-no-fork" = {
        expr = { inherit (sealedP) allowExecve allowFork; };
        expected = { allowExecve = false; allowFork = false; };
      };

      "profile-effectful-allows-exec-and-fork" = {
        expr = { inherit (effectfulP) allowExecve allowFork; };
        expected = { allowExecve = true; allowFork = true; };
      };

      "toBwrap-sealed-no-dns-no-dns-binds" = {
        expr =
          let args = toBwrap sealedP;
          in {
            hasResolvBind = builtins.elem "/etc/resolv.conf" args;
            hasNsswitchBind = builtins.elem "/etc/nsswitch.conf" args;
          };
        expected = {
          hasResolvBind = false;
          hasNsswitchBind = false;
        };
      };

      "toBwrap-emits-ro-store-bind" = {
        expr =
          let args = toBwrap sealedP;
          in lib.lists.sublist 0 3 args;
        expected = [ "--ro-bind" "/nix/store" "/nix/store" ];
      };

      "toBwrap-emits-tmpfs-tmp" = {
        expr = builtins.elem "--tmpfs" (toBwrap sealedP)
          && builtins.elem "/tmp" (toBwrap sealedP);
        expected = true;
      };

      "toBwrap-non-daemon-includes-unshare-pid-and-die-with-parent" = {
        expr =
          let args = toBwrap sealedP;
          in {
            hasUnsharePid = builtins.elem "--unshare-pid" args;
            hasDieWithParent = builtins.elem "--die-with-parent" args;
          };
        expected = {
          hasUnsharePid = true;
          hasDieWithParent = true;
        };
      };

      "toBwrap-daemon-mode-omits-unshare-pid-and-die-with-parent" = {
        expr =
          let
            daemonP = sandboxProfile { daemonMode = true; };
            args = toBwrap daemonP;
          in
          {
            hasUnsharePid = builtins.elem "--unshare-pid" args;
            hasDieWithParent = builtins.elem "--die-with-parent" args;
          };
        expected = {
          hasUnsharePid = false;
          hasDieWithParent = false;
        };
      };

      "toBwrap-stdio-true-omits-null-redirects" = {
        expr = builtins.elem "/dev/stdin" (toBwrap sealedP);
        expected = false;
      };

      "toBwrap-stdio-false-redirects-to-dev-null" = {
        expr =
          let p = sandboxProfile { stdio = false; };
          in builtins.elem "/dev/stdin" (toBwrap p);
        expected = true;
      };

      "toLandlock-emits-typed-shape" = {
        expr = (toLandlock sealedP)._con;
        expected = "MetaBuilderLandlockProfile";
      };

      "toLandlock-extracts-ports-from-tcp-endpoints" = {
        expr =
          let
            p = sandboxProfile {
              listenTcp = [ (tcpEndpoint { port = 8080; }) (tcpEndpoint { port = 4005; }) ];
              connectTcp = [ (tcpEndpoint { port = 5432; }) ];
            };
          in
          {
            listen = (toLandlock p).listenPorts;
            connect = (toLandlock p).connectPorts;
          };
        expected = {
          listen = [ 8080 4005 ];
          connect = [ 5432 ];
        };
      };

      "toLandlock-flattens-tmpfs-into-readWritePaths" = {
        expr =
          let
            p = sandboxProfile {
              readWritePaths = [ "/var/lib/app" ];
              tmpfs = [ "/tmp" "/run/user" ];
            };
          in
          (toLandlock p).readWritePaths;
        expected = [ "/var/lib/app" "/tmp" "/run/user" ];
      };

      "toLandlock-passes-connect-any-through" = {
        expr = {
          deflt = (toLandlock sealedP).connectAny;
          open = (toLandlock (sandboxProfile { connectAny = true; })).connectAny;
        };
        expected = { deflt = false; open = true; };
      };

      "combinators-connect-any-sets-flag" = {
        expr =
          let inherit (combinators) compose sealed connectAny;
          in (compose [ sealed connectAny ]).connectAny;
        expected = true;
      };

      "toSeccomp-returns-thunk" = {
        expr = fx.state.isThunk (toSeccomp sealedP seccompStages.Self);
        expected = true;
      };

      # Exec syscalls ride in every stage-profile cell but Self & sealed.
      "toSeccomp-exec-syscalls-cover-stage-profile-matrix" = {
        expr =
          let
            hasExec = profile: stage: builtins.elem "execve"
              (compileSeccomp.flattenPolicy {
                categories = seccompCategoriesFor profile stage;
              });
          in
          {
            bwrapSealed = hasExec sealedP seccompStages.Bwrap;
            bwrapEffectful = hasExec effectfulP seccompStages.Bwrap;
            selfSealed = hasExec sealedP seccompStages.Self;
            selfEffectful = hasExec effectfulP seccompStages.Self;
          };
        expected = {
          bwrapSealed = true;
          bwrapEffectful = true;
          selfSealed = false;
          selfEffectful = true;
        };
      };

      "toSystemd-sealed-excludes-execve" = {
        expr =
          let s = toSystemd sealedP;
          in {
            shape = s._con;
            excludesExecve = builtins.elem "~execve" s.systemCallFilter;
          };
        expected = {
          shape = "MetaBuilderSystemdHardening";
          excludesExecve = true;
        };
      };

      "toSystemd-effectful-allows-execve" = {
        expr =
          let s = toSystemd effectfulP;
          in {
            excludesExecve = builtins.elem "~execve" s.systemCallFilter;
            baseFilter = builtins.elem "@system-service" s.systemCallFilter;
          };
        expected = {
          excludesExecve = false;
          baseFilter = true;
        };
      };

      "syscall-sets-twelve-generic-categories" = {
        expr = builtins.sort builtins.lessThan (builtins.attrNames compileSeccomp.syscallSets);
        expected = builtins.sort builtins.lessThan [
          "memory"
          "fileIo"
          "network"
          "signals"
          "threading"
          "processInfo"
          "time"
          "ipc"
          "fileManagement"
          "landlock"
          "seccompSelf"
          "processExec"
        ];
      };

      "seccomp-stage-re-export-closed-sum" = {
        expr = {
          bwrapTag = seccompStages.Bwrap._con;
          selfTag = seccompStages.Self._con;
        };
        expected = {
          bwrapTag = "Bwrap";
          selfTag = "Self";
        };
      };

      "combinators-compose-listen-accumulates" = {
        expr =
          let
            inherit (combinators) compose sealed listen;
            p = compose [ sealed (listen 8080) (listen 9000) ];
          in
          map (e: e.port) p.listenTcp;
        expected = [ 8080 9000 ];
      };

      "combinators-readwrite-emits-rw-bind" = {
        expr =
          let
            inherit (combinators) compose sealed readwrite;
            p = compose [ sealed (readwrite "/var/lib/state") ];
          in
          p.readWritePaths;
        expected = [ "/var/lib/state" ];
      };

      "define-rejects-malformed-listen-endpoint" = {
        expr = (builtins.tryEval (builtins.deepSeq
          (define { listenTcp = [{ _con = "MetaBuilderTcpEndpoint"; port = "no"; address = "127.0.0.1"; }]; })
          null)).success;
        expected = false;
      };
    };
}
