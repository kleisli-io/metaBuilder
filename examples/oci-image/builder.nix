{ mb, pkgs, ... }:

let
  ops = mb.operations;
  oci = mb.ornaments."oci-image";

  spec = oci.ociImage {
    name = "busybox-shell";
    layers = [
      { name = "busybox"; source = pkgs.pkgsStatic.busybox; }
    ];
    entrypoint = [ "/bin/sh" ];
    evidence = [
      (ops.evidence {
        name = "smoke-test";
        payload = {
          command = "/bin/sh -c 'echo oci-smoke-ok'";
          expectedOutput = "oci-smoke-ok";
        };
      })
    ];
  };

  program = mb.program.fromOrnamentedSpec oci.OciImageBuilder.T spec;

  value = {
    builder = {
      inherit (oci) OciImageBuilder ociImage descriptor schema;
    };
    inherit spec program;
    validation = mb.program.validate.run program;
    deps = mb.program.deps.run program;
    dryRun = mb.program."dry-run".run program;
    planView = mb.program."plan-view".run program;
    docs = mb.program.describe.run program;
    selfView = mb.program.introspect.run program;
    materialize = mb.program.materialize.run program;
  };

in
{
  scope = {
    inherit spec program value;
  };
}
