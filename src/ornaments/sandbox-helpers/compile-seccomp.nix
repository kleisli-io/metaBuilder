{ pkgs, lib }:

let
  # Standalone BPF compiler. Reads a syscall allowlist (one name per
  # line) and emits a binary BPF program suitable for bubblewrap's
  # `--seccomp` fd. No consumer-specific tuning — see
  # `gen-seccomp-bpf.c` for the source.
  generator = pkgs.runCommandCC "gen-seccomp-bpf"
    {
      buildInputs = [ pkgs.libseccomp ];
    } ''
    mkdir -p $out/bin
    $CC -O2 -Wall -Wextra ${./gen-seccomp-bpf.c} -lseccomp -o $out/bin/gen-seccomp-bpf
  '';

  # Generic syscall categories. Each category is a flat list of names
  # that a sandboxed Linux process may need. Categories compose freely
  # via `mkFilter { categories = [...]; }` which flattens and dedupes.
  syscallSets = {
    # Memory management. Universal — every libc process needs these.
    memory = [
      "mmap"
      "mprotect"
      "munmap"
      "mremap"
      "brk"
      "madvise"
    ];

    # Signal handling.
    signals = [
      "rt_sigaction"
      "rt_sigprocmask"
      "rt_sigreturn"
      "rt_sigsuspend"
      "sigaltstack"
      "tgkill"
    ];

    # Threading primitives. `clone3` with `CLONE_THREAD` only; full
    # `fork`/`vfork`/`clone` (without `CLONE_THREAD`) live in
    # `processExec`.
    threading = [
      "clone3"
      "futex"
      "set_robust_list"
      "get_robust_list"
      "rseq"
    ];

    # File I/O. Path-level access control is enforced by Landlock, not
    # seccomp.
    fileIo = [
      "openat"
      "read"
      "readv"
      "pread64"
      "write"
      "writev"
      "pwrite64"
      "close"
      "close_range"
      "fstat"
      "newfstatat"
      "lseek"
      "fcntl"
      "dup"
      "dup2"
      "ioctl"
      "getdents64"
      "ftruncate"
      "readlink"
      "readlinkat"
      "access"
      "faccessat"
      "faccessat2"
      "getcwd"
      "chdir"
    ];

    # File management (create/delete/rename). Path-level access control
    # is enforced by Landlock, not seccomp.
    fileManagement = [
      "unlink"
      "unlinkat"
      "rename"
      "renameat"
      "renameat2"
      "mkdir"
      "mkdirat"
      "symlink"
      "symlinkat"
      "chmod"
      "fchmod"
      "fchmodat"
    ];

    # Network — TCP/UDP/Unix sockets and polling primitives. Port-level
    # filtering is out of scope for seccomp; that's a Landlock/iptables
    # concern.
    network = [
      "socket"
      "bind"
      "listen"
      "accept"
      "accept4"
      "connect"
      "sendto"
      "recvfrom"
      "sendmsg"
      "recvmsg"
      "getsockopt"
      "setsockopt"
      "getsockname"
      "getpeername"
      "shutdown"
      "poll"
      "ppoll"
      "select"
      "pselect6"
      "epoll_create"
      "epoll_create1"
      "epoll_ctl"
      "epoll_wait"
      "epoll_pwait"
    ];

    # Process info — read-only identity/limit queries.
    processInfo = [
      "getpid"
      "gettid"
      "getuid"
      "getgid"
      "geteuid"
      "getegid"
      "getresuid"
      "getresgid"
      "getppid"
      "getpgrp"
      "setpgid"
      "arch_prctl"
      "set_tid_address"
      "uname"
      "sysinfo"
      "prlimit64"
    ];

    # Time and timers.
    time = [
      "clock_gettime"
      "clock_getres"
      "clock_nanosleep"
      "nanosleep"
      "timer_create"
      "timer_settime"
      "timer_delete"
      "timer_gettime"
      "timer_getoverrun"
      "setitimer"
      "getitimer"
    ];

    # IPC and miscellaneous.
    ipc = [
      "pipe2"
      "eventfd2"
      "getrandom"
      "prctl"
      "exit"
      "exit_group"
    ];

    # Process execution (fork + exec). Include only for profiles that
    # legitimately spawn child processes.
    processExec = [
      "execve"
      "execveat"
      "fork"
      "vfork"
      "clone"
      "wait4"
      "waitid"
    ];

    # Landlock self-restriction syscalls. Include when the process
    # applies its own Landlock ruleset post-init.
    landlock = [
      "landlock_create_ruleset"
      "landlock_add_rule"
      "landlock_restrict_self"
    ];

    # seccomp(2) for stage-2 self-application. TSYNC requires the
    # syscall form — prctl(PR_SET_SECCOMP) cannot sync filters across
    # an already-threaded process. Safe under no_new_privs: additional
    # filters can only further restrict.
    seccompSelf = [
      "seccomp"
    ];
  };

in
rec {
  inherit generator syscallSets;

  flattenPolicy = { categories ? [ ], extra ? [ ] }:
    lib.unique (lib.concatLists categories ++ extra);

  mkAllowlist = { categories ? [ ], extra ? [ ], name ? "seccomp-policy" }:
    let syscalls = flattenPolicy { inherit categories extra; };
    in pkgs.writeText "${name}.allowlist" (
      "# Generated seccomp allowlist\n"
      + lib.concatMapStringsSep "\n" (s: s) syscalls
      + "\n"
    );

  mkFilter = { categories ? [ ], extra ? [ ], name ? "seccomp-filter" }:
    let allowlist = mkAllowlist { inherit categories extra; inherit name; };
    in pkgs.runCommand name { } ''
      mkdir -p $out
      ${generator}/bin/gen-seccomp-bpf ${allowlist} > $out/${name}.bpf
    '';
}
