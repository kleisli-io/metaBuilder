# metaBuilder docs content
#
# Produces a content directory of front-mattered markdown files keyed by
#   metaBuilder/{section}/{page}.md
# Consumed by external documentation hubs (kleisli-docs assembles this
# content into its serving tree). No assumptions about the hub leak into
# this file beyond the layout contract above.
#
# Hand-written chapters live flat under book/src/*.md with no front matter.
# Section grouping (Manual, Theory) and per-page title/description metadata
# live here, alongside the section landing prose. Merges those chapters
# with auto-generated API docs and guided examples.

{ pkgs, lib, metaBuilder }:

let
  docsLib = metaBuilder.docs;
  docsTree = metaBuilder.extractDocs;
  examplesDocs = metaBuilder.examplesDocs;
  bookSrc = ../src;

  inherit (docsLib) addFrontMatter trimText;

  project = {
    id = "metaBuilder";
    name = "metaBuilder";
    namespaceRoot = "mb";
    description = "Typed builder DSL built on nix-effects descriptions and internalized programs.";
    sourceUrl = "https://github.com/kleisli-io/metaBuilder";
    # Unlisted on docs.kleisli.io: excluded from hub/llms.txt/sitemap/search/MCP
    # listings, served by direct URL with noindex. Flip when published.
    draft = true;
  };
  apiSections = [
    {
      key = "program";
      url = "program";
      title = "Program";
      banner = "Internalized desc-interp program signature and execution interpretations.";
    }
    {
      key = "reference";
      url = "reference";
      title = "Reference";
      banner = "Schemas and datatype reference artifacts derived from descriptions.";
    }
    {
      key = "ornaments";
      url = "ornaments";
      title = "Ornaments";
      banner = "Typed builder extensions layered over shared descriptions.";
    }
    {
      key = "lib";
      url = "lib";
      title = "Library Helpers";
      banner = "Reusable helper modules for builder integration.";
    }
  ];
  preferredDocOrder = {
    "core-api" = [ "descriptions" "operations" ];
    program = [ "validate" "deps" "dry-run" "plan-view" "describe" "introspect" "materialize" ];
    reference = [ "schemas" "datatypes" ];
    ornaments = [
      "project-builder"
      "dependencies"
      "implementations"
      "toolEnv"
      "testing"
      "vendoring"
      "code-gen"
      "idl"
      "capabilities"
      "protocol"
      "service"
      "replServer"
      "sandbox"
      "transform"
    ];
    lib = [ "tool-env" "toolchain" "passthru" "bundled" "dashboard" ];
  };

  apiDocEntries = docsLib.makeApiEntries {
    inherit pkgs apiSections preferredDocOrder;
    docs = docsTree;
    projectId = project.id;
    namespaceRoot = project.namespaceRoot;
    libraryName = project.name;
  };

  sectionChildren = [
    {
      slug = "core-api";
      title = "Core API";
      order = 1;
      pages = apiDocEntries.coreModuleNames;
      banner = "Auto-generated API reference.";
    }
  ] ++ lib.imap1
    (i: sec: {
      slug = sec.url;
      title = sec.title;
      order = i + 1;
      pages = apiDocEntries.apiSectionPagePaths sec.url (docsTree.${sec.key} or { });
      banner = sec.banner or "Auto-generated API reference.";
    })
    apiSections;

  handwrittenSections = [
    {
      slug = "manual";
      title = "Manual";
      order = 1;
      description = "Practical guidance for writing and using metaBuilder builders as typed descriptions with reusable program views.";
      introduction = ''
        metaBuilder is a library for writing builders as typed descriptions. A builder
        names the structure of a build. That structure includes inputs, tools,
        operations, outputs, runtime shape, and evidence, so the same build can be
        validated, inspected, explained, and materialized.

        Use this manual when you want to design or consume a metaBuilder builder. It
        keeps the focus on the public model. You will see which values you write, which
        views you ask for, and how those views make a builder easier to understand.

        ## Path Through The Manual

        Start with [Introduction](/metaBuilder/manual/introduction) for the overall
        model. Then read [Getting Started](/metaBuilder/manual/getting-started) for the
        smallest complete flow.

        The middle chapters explain the reusable pieces.

        - [Builder Specs](/metaBuilder/manual/builder-specs)
        - [Operations](/metaBuilder/manual/operations)
        - [Programs And Views](/metaBuilder/manual/programs-and-views)
        - [Designing Builder Surfaces](/metaBuilder/manual/designing-builder-surfaces)

        The final chapters explain how to return useful artifacts and grow a small
        builder into a production builder.

        - [Outputs, Evidence, And Runtime Artifacts](/metaBuilder/manual/outputs-evidence-runtime)
        - [Materialization Model](/metaBuilder/manual/materialization-model)
        - [Authoring Production Builders](/metaBuilder/manual/authoring-production-builders)

        For complete guided examples, read the examples section after the manual.
      '';
      pages = [
        {
          slug = "introduction";
          title = "Introduction";
          description = "metaBuilder treats builders as typed descriptions, giving one build reusable validation, inspection, documentation, and materialization views.";
        }
        {
          slug = "getting-started";
          title = "Getting Started";
          description = "Define a small builder spec, construct a program, and run validate, dry-run, plan-view, introspect, and materialize.";
        }
        {
          slug = "builder-specs";
          title = "Builder Specs";
          description = "Builder specs name parameters, inputs, dependencies, tools, operations, outputs, and evidence before materialization.";
        }
        {
          slug = "operations";
          title = "Operations";
          description = "Operations describe build intent as data: read inputs, declare tools, write files, run commands, emit descriptors, and materialize.";
        }
        {
          slug = "programs-and-views";
          title = "Programs And Views";
          description = "The same builder program supports validation, dependency graph, dry-run, plan-view, describe, introspect, and materialization.";
        }
        {
          slug = "designing-builder-surfaces";
          title = "Designing Builder Surfaces";
          description = "Design builders from domain vocabulary first, then lower small public constructors into the shared metaBuilder program model.";
        }
        {
          slug = "outputs-evidence-runtime";
          title = "Outputs, Evidence, And Runtime Artifacts";
          description = "Outputs, descriptors, evidence, services, protocols, and runtime units describe what an artifact is and how it should run.";
        }
        {
          slug = "materialization-model";
          title = "Materialization Model";
          description = "Materialization interprets a builder program as a plan that produces derivations, outputs, and runtime declarations.";
        }
        {
          slug = "authoring-production-builders";
          title = "Authoring Production Builders";
          description = "Grow production builders from small domain constructors, explicit descriptors, standard views, and view-focused tests.";
        }
      ];
    }
    {
      slug = "theory";
      title = "Theory";
      order = 2;
      description = "Mathematical framing for builders as descriptions, internalized programs, ornaments, interpretations, and runtime structure.";
      introduction = ''
        The theory section explains the ideas behind metaBuilder. It is a companion to
        the manual and not a prerequisite for using the library.

        The practical claim is short. A build can be written as typed data, that data
        can be read as a program, and the program can be interpreted in more than one
        way. The theory chapters make each part of that claim precise.

        A builder is a typed description rather than a function. The description becomes
        a program over a fixed signature of build-time and runtime operations. Domain
        builders refine the description with extra data through ornaments, and a typed
        forget map projects them back to the shared shape without losing the program.
        Every view is an interpretation of that one program.

        - [Builders As Descriptions](/metaBuilder/theory/builders-as-descriptions)
        - [Internalized Programs](/metaBuilder/theory/internalized-programs)
        - [Ornaments And Domain Surfaces](/metaBuilder/theory/ornaments-and-domain-surfaces)
        - [Interpretation And Views](/metaBuilder/theory/interpretation-and-views)
        - [Evidence, Descriptors, And Runtime Structure](/metaBuilder/theory/evidence-descriptors-runtime)

        Read this section when you want to understand why metaBuilder can support one
        build with many views.
      '';
      pages = [
        {
          slug = "builders-as-descriptions";
          title = "Builders As Descriptions";
          description = "A build description is structured data that can be checked, summarized, documented, interpreted, and materialized.";
        }
        {
          slug = "internalized-programs";
          title = "Internalized Programs";
          description = "Internalized programs represent build workflows as reusable values shared by validation, explanation, and materialization views.";
        }
        {
          slug = "ornaments-and-domain-surfaces";
          title = "Ornaments And Domain Surfaces";
          description = "Ornaments enrich the shared builder shape with domain-specific fields while preserving common interpretation behavior.";
        }
        {
          slug = "interpretation-and-views";
          title = "Interpretation And Views";
          description = "Each view is an interpretation of the same builder program: validation, graph, dry-run, plan, documentation, or artifact.";
        }
        {
          slug = "evidence-descriptors-runtime";
          title = "Evidence, Descriptors, And Runtime Structure";
          description = "Evidence, descriptors, services, protocols, and units belong in the descriptive model because artifacts have meaning beyond build success.";
        }
      ];
    }
  ];

  handwrittenSectionManifest = map
    (section: {
      inherit (section) slug title order;
      pages = map (page: page.slug) section.pages;
      banner = section.description;
    })
    handwrittenSections;

  handwrittenEntries = lib.concatMap
    (section:
      map
        (page: {
          name = "${project.id}/${section.slug}/${page.slug}.md";
          path = pkgs.writeText "${section.slug}-${page.slug}.md" (addFrontMatter {
            inherit (page) title description;
            body = builtins.readFile (bookSrc + "/${page.slug}.md");
          });
        })
        section.pages)
    handwrittenSections;

  handwrittenIndexEntries = map
    (section: {
      name = "${project.id}/${section.slug}/index.md";
      path = pkgs.writeText "${section.slug}-index.md" (addFrontMatter {
        inherit (section) title description;
        body = section.introduction;
      });
    })
    handwrittenSections;

  orderNames = preferred: names:
    let
      selected = lib.filter (n: builtins.elem n names) preferred;
      rest = lib.filter (n: !(builtins.elem n preferred)) names;
    in
    selected ++ lib.sort (a: b: a < b) rest;

  exampleNames = orderNames [ "node-service" "c-codegen" "bridge" "idl" ]
    (builtins.attrNames examplesDocs);

  titleFor = name: node:
    let title = node.title or "";
    in if title != "" then title else docsLib.capitalise (builtins.replaceStrings [ "-" ] [ " " ] name);

  sourceSlug = exampleName: source:
    "${exampleName}/source/${source.name or (baseNameOf (source.relativePath or (toString source.source)))}";

  sourceIndexSlug = exampleName: "${exampleName}/source";

  sourcePath = source:
    source.relativePath or source.path or (source.name or (baseNameOf (toString source.source)));

  sourceTitle = source:
    if source ? title then source.title else sourcePath source;

  sourceFilesFor = node: node.sourceFiles or [ ];

  sourcePageSlugsFor = name: node:
    map (source: sourceSlug name source) (sourceFilesFor node);

  sourceSlugsFor = name: node:
    let sourceFiles = sourceFilesFor node;
    in lib.optional (sourceFiles != [ ]) (sourceIndexSlug name)
    ++ sourcePageSlugsFor name node;

  examplePages = lib.concatMap
    (name: [ name ] ++ sourceSlugsFor name examplesDocs.${name})
    exampleNames;

  renderExampleSection = section:
    let
      title = section.title or "";
      body = section.body or (section.prose or "");
      code = section.code or "";
    in
    lib.optionalString (title != "") "## ${title}\n\n"
    + lib.optionalString (body != "") "${trimText body}\n\n"
    + lib.optionalString (code != "") "```nix\n${trimText code}\n```\n\n";

  renderSourceList = name: node:
    let
      sourceFiles = sourceFilesFor node;
    in
    lib.optionalString (sourceFiles != [ ]) (
      "## Source files\n\n"
      + "These pages are the complete source for the worked example: the builder module plus the files it consumes.\n\n"
      + lib.concatMapStringsSep "\n"
        (source:
          "- [${sourceTitle source}](/${project.id}/examples/${sourceSlug name source})"
          + lib.optionalString (source.description or "" != "") " - ${source.description}")
        sourceFiles
      + "\n\n"
    );

  renderExamplePage = name: node:
    let
      title = titleFor name node;
      intro =
        if node.doc or "" != "" then trimText node.doc
        else trimText (node.description or "");
      sections = node.sections or [ ];
      sourceList = renderSourceList name node;
      sectionBody =
        if sourceList != "" && sections != [ ]
        then renderExampleSection (builtins.head sections)
          + sourceList
          + lib.concatMapStrings renderExampleSection (builtins.tail sections)
        else sourceList + lib.concatMapStrings renderExampleSection sections;
    in
    addFrontMatter {
      inherit title;
      description = node.description or null;
      body = "${intro}\n\n${sectionBody}";
    };

  renderSourceOverviewPage = name: node:
    let
      title = "Source files";
      exampleTitle = titleFor name node;
      sourceFiles = sourceFilesFor node;
    in
    addFrontMatter {
      inherit title;
      description = "Complete source files for ${exampleTitle}.";
      body = ''
        These files are the complete source for ${exampleTitle}: the
        builder module plus the fixtures it consumes.

        ${lib.concatMapStringsSep "\n"
          (source:
            "- [${sourceTitle source}](/${project.id}/examples/${sourceSlug name source})"
            + lib.optionalString (source.description or "" != "") " - ${source.description}")
          sourceFiles}
      '';
    };

  renderSourcePage = exampleName: source:
    let
      title = sourceTitle source;
      language = source.language or "";
      code =
        if source ? text
        then source.text
        else builtins.readFile source.source;
      description = source.description or "Source file for the ${titleFor exampleName examplesDocs.${exampleName}} guided example.";
      role = source.role or "";
      rel = sourcePath source;
      sourceUrl = "${project.sourceUrl}/blob/main/${rel}";
    in
    addFrontMatter {
      inherit title description;
      body =
        lib.optionalString (role != "") "${trimText role}\n\n"
        + "Source path: [`${rel}`](${sourceUrl}).\n\n"
        + "```" + language + "\n"
        + code
        + lib.optionalString (!(lib.hasSuffix "\n" code)) "\n"
        + "```\n";
    };

  exampleEntries = map
    (name: {
      name = "${project.id}/examples/${name}.md";
      path = pkgs.writeText "${name}.md" (renderExamplePage name examplesDocs.${name});
    })
    exampleNames;

  sourceEntries = lib.concatMap
    (name:
      map
        (source: {
          name = "${project.id}/examples/${sourceSlug name source}.md";
          path = pkgs.writeText "${name}-${source.name or "source"}.md" (renderSourcePage name source);
        })
        (sourceFilesFor examplesDocs.${name}))
    exampleNames;

  sourceOverviewEntries = lib.concatMap
    (name:
      lib.optional (sourceFilesFor examplesDocs.${name} != [ ]) {
        name = "${project.id}/examples/${sourceIndexSlug name}.md";
        path = pkgs.writeText "${name}-source-files.md" (renderSourceOverviewPage name examplesDocs.${name});
      })
    exampleNames;

  exampleOverviewEntry = {
    name = "${project.id}/examples/index.md";
    path = pkgs.writeText "examples-index.md" (addFrontMatter {
      title = "Examples";
      description = "Runnable example builders that demonstrate metaBuilder internalized programs.";
      body = ''
        metaBuilder examples are builder definitions with source
        fixtures, self-documentation, tests, materialization plans, and
        generated artifacts.

        ${lib.concatMapStringsSep "\n"
          (name: "- [${titleFor name examplesDocs.${name}}](/${project.id}/examples/${name}) - ${examplesDocs.${name}.description or ""}")
          exampleNames}
      '';
    });
  };

  projectEntry = {
    name = "${project.id}/project.json";
    path = pkgs.writeText "project.json" (docsLib.mkProjectJson {
      inherit (project) id;
      name = project.name;
      description = project.description;
      sourceUrl = project.sourceUrl;
      draft = project.draft or false;
      sections = [
        (builtins.elemAt handwrittenSectionManifest 0)
        (builtins.elemAt handwrittenSectionManifest 1)
        {
          slug = "examples";
          title = "Examples";
          order = 3;
          pages = examplePages;
          banner = "Runnable builders with source fixtures, self-docs, and materialization plans.";
        }
        {
          title = "API Reference";
          order = 4;
          reference = true;
          children = sectionChildren;
        }
      ];
    });
  };

  indexEntry = {
    name = "${project.id}/index.md";
    path = pkgs.writeText "index.md" (addFrontMatter {
      title = project.name;
      description = project.description;
      body = builtins.readFile (bookSrc + "/index.md");
    });
  };

  rawCorpus = pkgs.linkFarm "${project.id}-docs-raw"
    ([ projectEntry indexEntry exampleOverviewEntry ]
      ++ handwrittenIndexEntries
      ++ handwrittenEntries
      ++ exampleEntries
      ++ sourceOverviewEntries
      ++ sourceEntries
      ++ apiDocEntries.entries);
in
pkgs.runCommand "${project.id}-docs" { } ''
  set -eu
  mkdir -p "$out"
  cp -a ${rawCorpus}/. "$out/"
''
