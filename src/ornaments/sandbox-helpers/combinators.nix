{ lib, mb }:

let
  inherit (mb.operations) sandboxProfile tcpEndpoint;

  unwrap = c: if c ? impl then c.impl else c;
  emptyProfile = sandboxProfile { };

in
rec {

  # Wrap an implementation function with self-documenting metadata
  # `{ sig; doc; impl }`. Plain functions are accepted too (see
  # `unwrap`) — combinator authors should prefer `mkCombinator` so the
  # combinator surfaces its signature and docstring to downstream
  # consumers.
  mkCombinator = { sig, doc, impl }: { inherit sig doc impl; };

  # Two-pass composition: immediate combinators apply left-to-right,
  # then deferred combinators apply on the result so they observe the
  # fully-accumulated profile.
  compose = combinators:
    let
      isDeferred = c: c.__deferred or false;
      immediate = builtins.filter (c: !isDeferred c) combinators;
      deferred = builtins.filter isDeferred combinators;
      intermediateProfile = lib.pipe emptyProfile (map unwrap immediate);
    in
    lib.pipe intermediateProfile (map unwrap deferred);

  sealed = mkCombinator {
    sig = "Profile -> Profile";
    doc = "Sealed base profile: read-only /nix/store, /tmp tmpfs, no network, no exec.";
    impl = _: sandboxProfile { };
  };

  effectful = mkCombinator {
    sig = "Profile -> Profile";
    doc = "Effectful base profile: allows execve and fork.";
    impl = _: sandboxProfile { allowExecve = true; allowFork = true; };
  };

  listen = port: mkCombinator {
    sig = "Int -> Profile -> Profile";
    doc = "Add a TCP listen endpoint at 127.0.0.1:port. Accumulates.";
    impl = profile: profile // {
      listenTcp = profile.listenTcp ++ [ (tcpEndpoint { inherit port; }) ];
    };
  };

  connectTo = port: mkCombinator {
    sig = "Int -> Profile -> Profile";
    doc = "Add a TCP connect endpoint at 127.0.0.1:port. Accumulates.";
    impl = profile: profile // {
      connectTcp = profile.connectTcp ++ [ (tcpEndpoint { inherit port; }) ];
    };
  };

  connectAny = mkCombinator {
    sig = "Profile -> Profile";
    doc = ''
      Leave outbound TCP connect UNRESTRICTED (CONNECT_TCP not handled by the
      Landlock ruleset). Listen/bind stays restricted; FS-read-only, no-execve,
      and seccomp protections are unaffected. Landlock TCP rules are
      port-based/host-blind, so a connect allowlist gives no real egress
      protection while breaking tools that must reach arbitrary peers.
    '';
    impl = profile: profile // { connectAny = true; };
  };

  readonly = path: mkCombinator {
    sig = "Path -> Profile -> Profile";
    doc = "Bind-mount a path read-only. Accumulates.";
    impl = profile: profile // {
      readOnlyPaths = profile.readOnlyPaths ++ [ path ];
    };
  };

  readwrite = path: mkCombinator {
    sig = "Path -> Profile -> Profile";
    doc = "Bind-mount a path read-write. Accumulates.";
    impl = profile: profile // {
      readWritePaths = profile.readWritePaths ++ [ path ];
    };
  };

  allowExec = mkCombinator {
    sig = "Profile -> Profile";
    doc = "Allow execve. Required for programs that spawn subprocesses.";
    impl = profile: profile // { allowExecve = true; };
  };

  allowFork = mkCombinator {
    sig = "Profile -> Profile";
    doc = "Allow fork without exec.";
    impl = profile: profile // { allowFork = true; };
  };

  daemon = mkCombinator {
    sig = "Profile -> Profile";
    doc = "Enable daemon mode — omits --die-with-parent / --unshare-pid from bwrap.";
    impl = profile: profile // { daemonMode = true; };
  };

  defer = c:
    let fn = unwrap c; in {
      __deferred = true;
      sig = "(Profile -> Profile) -> Deferred Combinator";
      doc = "Run after all non-deferred combinators in compose.";
      impl = fn;
    };
}
