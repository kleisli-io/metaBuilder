{ mb, ... }:

let
  idl = mb.ornaments.idl;

  spec = idl.fromProtobuf {
    name = "example-idl";
    protos = [ ./schema.proto ];
    languages = [ "cpp" "java" ];
  };

  program = mb.program.fromOrnamentedSpec idl.IdlBuilder.T spec;

  value = {
    builder = {
      inherit (idl) IdlBuilder fromProtobuf descriptor schema;
    };
    inherit spec program;
    validation = mb.program.validate.run program;
    deps = mb.program.deps.run program;
    dryRun = mb.program."dry-run".run program;
    planView = mb.program."plan-view".run program;
    docs = mb.program.describe.run program;
    selfView = mb.program.introspect.run program;
    materialize = mb.program.materialize.run program;
    schemas = mb.reference.schemas;
    datatypes = mb.reference.datatypes;
  };

in
{
  scope = {
    inherit spec program value;
  };
}
