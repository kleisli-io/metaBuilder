{ lib, self, mb, fx, ... }:

let
  H = fx.types.hoas;
  V = fx.types.generic.value;
  G = fx.types.generic;
  v = fx.types.verified;
  E = fx.tc.eval;
  C = fx.tc.conv;

  node = self.node-service.value;
  c = self.c-codegen.value;
  oci = self."oci-image".value;
  idl = self.idl.value;

  NodeBuilder = node.builder.NodeServiceBuilder;
  CBuilder = c.builder.CCodegenBuilder;
  OciBuilder = oci.builder.OciImageBuilder;
  IdlBuilder = idl.builder.IdlBuilder;
  CodeGenBuilder = mb.ornaments."code-gen".CodeGenBuilder;
  BuilderSpec = mb.descriptions.BuilderSpec;

  nodeSpecH = V.review NodeBuilder.T node.spec;
  cSpecH = V.review CBuilder.T c.spec;
  ociSpecH = V.review OciBuilder.T oci.spec;
  idlSpecH = V.review IdlBuilder.T idl.spec;

  nodeBaseSpec = G.ornaments.forget NodeBuilder node.spec;
  cBaseSpec = G.ornaments.forget CBuilder c.spec;
  ociBaseSpec = G.ornaments.forget OciBuilder oci.spec;
  nodeBaseSpecH = V.review BuilderSpec.T nodeBaseSpec;
  cBaseSpecH = V.review BuilderSpec.T cBaseSpec;
  ociBaseSpecH = V.review BuilderSpec.T ociBaseSpec;

  # IdlBuilder ornaments CodeGenBuilder, which ornaments BuilderSpec, so
  # reaching the common base takes two forget steps.
  idlCgSpec = G.ornaments.forget IdlBuilder idl.spec;
  idlBaseSpec = G.ornaments.forget CodeGenBuilder idlCgSpec;
  idlCgSpecH = V.review CodeGenBuilder.T idlCgSpec;
  idlBaseSpecH = V.review BuilderSpec.T idlBaseSpec;

  # forget keeps `operations` and `evidence` — everything compileSpec
  # reads — so compiling the forgotten base spec rebuilds the same
  # program as the ornamented spec: compilation factors through forget.
  nodeBaseProgram = mb.program.fromSpec nodeBaseSpec;
  cBaseProgram = mb.program.fromSpec cBaseSpec;
  ociBaseProgram = mb.program.fromSpec ociBaseSpec;
  idlBaseProgram = mb.program.fromSpec idlBaseSpec;

  # The compiled effect lists (operations + lowered evidence): the same
  # input the live interpreters fold, so the kernel fold and the drift
  # check exercise every constructor the live path sees.
  nodeCompiledOps = mb.program.compileSpec BuilderSpec.T nodeBaseSpec;
  cCompiledOps = mb.program.compileSpec BuilderSpec.T cBaseSpec;
  ociCompiledOps = mb.program.compileSpec BuilderSpec.T ociBaseSpec;
  idlCompiledOps = mb.program.compileSpec BuilderSpec.T idlBaseSpec;

  # The canonical program for each example, recomputed from its spec.
  nodeFromSpec = mb.program.fromOrnamentedSpec NodeBuilder.T node.spec;
  cFromSpec = mb.program.fromOrnamentedSpec CBuilder.T c.spec;
  ociFromSpec = mb.program.fromOrnamentedSpec OciBuilder.T oci.spec;
  idlFromSpec = mb.program.fromOrnamentedSpec IdlBuilder.T idl.spec;

  evalHoas = term: E.eval [ ] (H.elab term);

  phrase = text: math: { inherit text math; };
  term = text: math: value: { inherit text math value; };

  # heavy: the check normalizes large concrete terms (minutes of kernel
  # evaluation); its test lands in the heavy suite instead of the default.
  kernelCheck = { name, statement, type, proof, heavy ? false }:
    let result = H.checkHoas type.value proof.value;
    in {
      inherit name heavy;
      statement = statement.text;
      statementMath = statement.math;
      type = type.text;
      typeMath = type.math;
      proof = proof.text;
      proofMath = proof.math;
      kind = "kernel-check";
      ok = !(result ? error);
      resultTag = result.tag or "error";
      # Lazy: reading statement fields must not force the kernel check.
      error = result.error or null;
    };

  kernelConversion = { name, statement, type, proof, lhs, rhs }:
    let ok = C.conv 0 (evalHoas lhs) (evalHoas rhs);
    in {
      inherit name ok;
      statement = statement.text;
      statementMath = statement.math;
      type = type.text;
      typeMath = type.math;
      proof = proof.text;
      proofMath = proof.math;
      kind = "kernel-conversion";
      resultTag = if ok then "definitional-equality" else "mismatch";
    };

  builderEffSum = H.sum mb.descriptions.BuilderOp.T mb.descriptions.RuntimeOp.T;

  noError = result: !(result ? error);

  # The renderer ρ : BuildPlanStep → String as a kernel term. opaqueLam carries
  # the live renderStep as an unverified trust boundary; String is axiomatised so
  # ρ never reduces. Structural step-fold coherence only needs both folds to apply
  # this same ρ, so the renderer body stays opaque.
  rhoTy = H.forall "_" mb.descriptions.BuildPlanStep.T (_: H.string);
  rho = H.opaqueLam mb.program.materialize.renderStep rhoTy;
  rhoCheck =
    let typeChecks = noError (H.checkHoas rhoTy rho);
    in { inherit typeChecks; ok = typeChecks; };

  # `mb.descriptions.BuildPlanStep.T` is the kernel step carrier directly
  # (descriptions.nix). Steps are born finalized: runStep's tool is
  # FinalizedToolSpec (all-string fields). The remaining opaque leaves —
  # SourceSpec.T's `any`, env's `attrs` — are axiomatised kernel primitives,
  # so the structural step-fold threads eliminator-bound payloads through it
  # with no fabricated literals. This gate confirms the carrier forms and its
  # emitting constructors inhabit with payloads threaded as bound variables
  # (exactly matFoldK's usage), and the param-instantiated
  # `args : listOf string` field checks.
  planStep =
    let
      BPS = mb.descriptions.BuildPlanStep;
      FinalizedToolSpec = mb.descriptions.FinalizedToolSpec;
      SourceSpec = mb.descriptions.SourceSpec;
      app3 = f: a: b: c: H.app (H.app (H.app f a) b) c;
      app4 = f: a: b: c: d: H.app (H.app (H.app (H.app f a) b) c) d;

      typeForms = noError (H.checkHoas (H.u 0) BPS.T);

      # The threading case matFoldK's runTool branch produces: name/tool/args/env
      # all arrive as bound variables at the constructor's field types.
      runThreadTy =
        H.forall "name" H.string (_:
        H.forall "tool" FinalizedToolSpec.T (_:
        H.forall "args" (H.listOf H.string) (_:
        H.forall "env" H.attrs (_: BPS.T))));
      runThreadTm =
        H.lam "name" H.string (name:
        H.lam "tool" FinalizedToolSpec.T (tool:
        H.lam "args" (H.listOf H.string) (args:
        H.lam "env" H.attrs (env:
          app4 BPS.runStep name tool args env))));
      runStepThreads = noError (H.checkHoas runThreadTy runThreadTm);

      # The param-instantiated literal: args built as a `cons` literal checked
      # against `listOf string` (the ann-strip target), tool/env threaded as vars.
      runLitTy = H.forall "tool" FinalizedToolSpec.T (_: H.forall "env" H.attrs (_: BPS.T));
      runLitTm =
        H.lam "tool" FinalizedToolSpec.T (tool:
        H.lam "env" H.attrs (env:
          app4 BPS.runStep (H.stringLit "n") tool
            (H.cons (H.stringLit "a") H.nil) env));
      runStepLitArgs = noError (H.checkHoas runLitTy runLitTm);

      writeStepInhabits = noError (H.checkHoas BPS.T
        (app3 BPS.writeStep (H.stringLit "w") (H.stringLit "/out/f") (H.stringLit "txt")));

      # copyStep threads source : SourceSpec.T as a bound variable.
      copyTy = H.forall "source" SourceSpec.T (_: BPS.T);
      copyTm = H.lam "source" SourceSpec.T (source:
        app3 BPS.copyStep (H.stringLit "c") source (H.stringLit "/out/d"));
      copyStepThreads = noError (H.checkHoas copyTy copyTm);
    in
    {
      inherit typeForms runStepThreads runStepLitArgs writeStepInhabits copyStepThreads;
      ok = typeForms && runStepThreads && runStepLitArgs && writeStepInhabits && copyStepThreads;
    };

  # matFoldK : listOf BuilderEff → listOf BuildPlanStep — the kernel
  # internalisation of materialize's step emission. v.matchSum splits the
  # sum-injected ops; v.matchData runs the per-op BuilderOp/RuntimeOp
  # eliminators, consing each emitted step into the fold accumulator.
  matFold =
    let
      BPS = mb.descriptions.BuildPlanStep;
      BOp = mb.descriptions.BuilderOp;
      ROp = mb.descriptions.RuntimeOp;
      OutputSpec = mb.descriptions.OutputSpec;
      ToolSpec = mb.descriptions.ToolSpec;
      FinalizedToolSpec = mb.descriptions.FinalizedToolSpec;
      stepsTy = H.listOf BPS.T;
      app2 = f: a: b: H.app (H.app f a) b;
      app3 = f: a: b: c: H.app (H.app (H.app f a) b) c;
      app4 = f: a: b: c: d: H.app (H.app (H.app (H.app f a) b) c) d;
      outName = output: v.field OutputSpec.T "name" output;
      outPath = output: v.field OutputSpec.T "path" output;

      # materialize finalizes the tool at emission (finalizeTool : ToolSpec →
      # FinalizedToolSpec); its package projection forces a live derivation —
      # a trust boundary the kernel cannot compute. The internalised emitter
      # threads the ρ-visible `name` through both string fields; `package` is
      # trust-boundary payload, reattached from the live step at the render
      # comparison (renderableStep).
      finalizeK = H.ann
        (H.lam "tool" ToolSpec.T (tool:
          app2 FinalizedToolSpec.MetaBuilderFinalizedTool
            (v.field ToolSpec.T "name" tool)
            (v.field ToolSpec.T "name" tool)))
        (H.forall "_" ToolSpec.T (_: FinalizedToolSpec.T));

      # Per-op emitter, fold-fused: each branch conses its step into `ih`
      # or passes `ih` through. matchData ann-wraps every body at stepsTy.
      matStepF = op: ih:
        v.matchSum BOp.T ROp.T stepsTy op {
          left = bop: v.matchData BOp stepsTy bop {
            readSource = name: source: ih;
            resolveDependency = dependency: ih;
            declareTool = tool: ih;
            runTool = name: tool: args: env:
              H.cons (app4 BPS.runStep name (H.app finalizeK tool) args env) ih;
            writeFile = output: text:
              H.cons (app3 BPS.writeStep (outName output) (outPath output) text) ih;
            copyPath = source: output:
              H.cons (app3 BPS.copyStep (outName output) source (outPath output)) ih;
            transformOutput = output: ih;
            validateValue = validation: ih;
            emitDescriptor = descriptor: ih;
            materializeDerivation = name: builder: ih;
            declareEvidence = evidence: ih;
          };
          right = rop: v.matchData ROp stepsTy rop {
            declareCapability = category: ih;
            declareProtocol = protocol: ih;
            declareService = service: ih;
            materializeUnit = name: ih;
          };
        };

      foldTy = H.forall "_" (H.listOf builderEffSum) (_: stepsTy);
      matFoldK = H.ann
        (H.lam "p" (H.listOf builderEffSum) (p:
          v.fold builderEffSum stepsTy H.nil
            (H.lam "op" builderEffSum (op: H.lam "ih" stepsTy (ih: matStepF op ih)))
            p))
        foldTy;

      nodeOpsH = V.review (H.listOf builderEffSum) nodeCompiledOps;
      cOpsH = V.review (H.listOf builderEffSum) cCompiledOps;

      # The catamorphism across the Pi extraction boundary: a Nix function
      # that elaborates its argument (raw operations, no prior review),
      # runs the verified closure, and extracts the step list back.
      matFoldX = fx.tc.elaborate.verifyAndExtract foldTy matFoldK;

      # Tag projection: the ρ-invisible structural skeleton of a step list.
      # The two interpreters differ on payloads (materialize synthesises a
      # name dry-run drops), so the honest agreement is at the tag level.
      StepTag = H.datatype "MetaBuilderStepTag" [
        (H.con "RunT" [ ])
        (H.con "WriteT" [ ])
        (H.con "CopyT" [ ])
        (H.con "MkdirT" [ ])
      ];
      tagsTy = H.listOf StepTag.T;

      # tagOf : BuildPlanStep → StepTag.
      tagOf = H.lam "s" BPS.T (s: v.matchData BPS StepTag.T s {
        runStep = name: tool: args: env: StepTag.RunT;
        writeStep = name: path: text: StepTag.WriteT;
        copyStep = name: source: path: StepTag.CopyT;
        mkdirStep = path: StepTag.MkdirT;
      });

      tagFoldTy = H.forall "_" (H.listOf builderEffSum) (_: tagsTy);

      # matTagFoldK = tagSeq ∘ matFoldK — the tag projection of the real
      # step catamorphism (mapped over its output, no refold).
      matTagFoldK = H.ann
        (H.lam "p" (H.listOf builderEffSum) (p:
          v.map BPS.T StepTag.T tagOf (H.app matFoldK p)))
        tagFoldTy;

      # dryTagFoldK internalises dry-run's tag-all + the dryRunStepCons
      # filter+rename to {run,write,copy}: a fold-fused emitter consing one
      # tag per emitting op, passing ih through otherwise.
      dryTagStepF = op: ih:
        v.matchSum BOp.T ROp.T tagsTy op {
          left = bop: v.matchData BOp tagsTy bop {
            readSource = name: source: ih;
            resolveDependency = dependency: ih;
            declareTool = tool: ih;
            runTool = name: tool: args: env: H.cons StepTag.RunT ih;
            writeFile = output: text: H.cons StepTag.WriteT ih;
            copyPath = source: output: H.cons StepTag.CopyT ih;
            transformOutput = output: ih;
            validateValue = validation: ih;
            emitDescriptor = descriptor: ih;
            materializeDerivation = name: builder: ih;
            declareEvidence = evidence: ih;
          };
          right = rop: v.matchData ROp tagsTy rop {
            declareCapability = category: ih;
            declareProtocol = protocol: ih;
            declareService = service: ih;
            materializeUnit = name: ih;
          };
        };
      dryTagFoldK = H.ann
        (H.lam "p" (H.listOf builderEffSum) (p:
          v.fold builderEffSum tagsTy H.nil
            (H.lam "op" builderEffSum (op: H.lam "ih" tagsTy (ih: dryTagStepF op ih)))
            p))
        tagFoldTy;

      tagConName = builtins.listToAttrs (lib.imap0
        (i: c: { name = "con${toString i}"; value = c.name; })
        (fx.tc.generic.datatype.datatypeInfo StepTag).constructors);
      extractTags = foldK: ops:
        map (s: tagConName.${s._con})
          (fx.tc.elaborate.verifyAndExtract tagsTy (H.app foldK ops));
      matTagCons = extractTags matTagFoldK;
      dryTagCons = extractTags dryTagFoldK;

      # ∀p structural agreement of the two tag folds, proved in the kernel:
      # map/fold fusion by induction on p. Under the induction binder the
      # cons head is neutral, so each step case-splits it (sumElim, then
      # elimData on the op payload) to expose a canonical constructor and
      # let ι-reduction fire through both folds. Emitting ops discharge by
      # J-congruence on the tag cons; the others pass the induction
      # hypothesis through unchanged; nil is refl.
      #
      # Construction constraints (each load-bearing):
      # - The folds are let_-bound once and every motive references the
      #   bound variables: eliminator wrappers ann-wrap each branch body
      #   against a meta-level copy of the motive, so embedding the fold
      #   terms directly multiplies them per branch and exhausts memory.
      # - The congruence step is a raw J with the function application
      #   already reduced in the motive; H.cong's motive embeds an
      #   unannotated meta-lam that does not elaborate in this position.
      # - cons literals are ann'd: polymorphic-constructor implicits do
      #   not solve in type position.
      # - Injections use the explicit forms at levelZero to match sumElim's
      #   internal construction (opt-in internal surface).
      inlOp = b: H._internal._indexed.inlAtExplicit H.levelZero BOp.T ROp.T b;
      inrOp = r: H._internal._indexed.inrAtExplicit H.levelZero BOp.T ROp.T r;
      consEff = h: t: H.ann (H.cons h t) (H.listOf builderEffSum);
      consTags = h: t: H.ann (H.cons h t) tagsTy;
      agreeAtF = matF: dryF: q: H.eq tagsTy (H.app matF q) (H.app dryF q);

      stepCongF = matF: dryF: t: ih: tag:
        H.j tagsTy (H.app matF t)
          (H.lam "w" tagsTy (w:
           H.lam "_p" (H.eq tagsTy (H.app matF t) w) (_:
             H.eq tagsTy
               (consTags tag (H.app matF t))
               (consTags tag w))))
          H.refl
          (H.app dryF t)
          ih;

      elimBopF = matF: dryF: t: ih: bop:
        v.elimData 0 BOp
          (H.lam "b" BOp.T (b: agreeAtF matF dryF (consEff (inlOp b) t)))
          bop
          {
            readSource = name: source: ih;
            resolveDependency = dependency: ih;
            declareTool = tool: ih;
            runTool = name: tool: args: env: stepCongF matF dryF t ih StepTag.RunT;
            writeFile = output: text: stepCongF matF dryF t ih StepTag.WriteT;
            copyPath = source: output: stepCongF matF dryF t ih StepTag.CopyT;
            transformOutput = output: ih;
            validateValue = validation: ih;
            emitDescriptor = descriptor: ih;
            materializeDerivation = name: builder: ih;
            declareEvidence = evidence: ih;
          };
      elimRopF = matF: dryF: t: ih: rop:
        v.elimData 0 ROp
          (H.lam "r" ROp.T (r: agreeAtF matF dryF (consEff (inrOp r) t)))
          rop
          {
            declareCapability = category: ih;
            declareProtocol = protocol: ih;
            declareService = service: ih;
            materializeUnit = name: ih;
          };

      sumSplitF = matF: dryF: t: ih: h:
        H.sumElim 0 BOp.T ROp.T
          (H.lam "hh" builderEffSum (hh: agreeAtF matF dryF (consEff hh t)))
          (H.lam "bop" BOp.T (bop: elimBopF matF dryF t ih bop))
          (H.lam "rop" ROp.T (rop: elimRopF matF dryF t ih rop))
          h;

      tagAgreeTy = H.forall "p" (H.listOf builderEffSum) (p:
        H.eq tagsTy (H.app matTagFoldK p) (H.app dryTagFoldK p));
      tagAgreeProof =
        H.let_ "matF" tagFoldTy matTagFoldK (matF:
        H.let_ "dryF" tagFoldTy dryTagFoldK (dryF:
          H.lam "p" (H.listOf builderEffSum) (p:
            H.listElim 0 builderEffSum
              (H.lam "q" (H.listOf builderEffSum) (q: agreeAtF matF dryF q))
              H.refl
              (H.lam "h" builderEffSum (h:
               H.lam "t" (H.listOf builderEffSum) (t:
               H.lam "ih" (agreeAtF matF dryF t) (ih:
                 sumSplitF matF dryF t ih h))))
              p)));
    in
    {
      inherit matFoldK foldTy nodeOpsH cOpsH matFoldX;
      inherit StepTag tagFoldTy matTagFoldK dryTagFoldK matTagCons dryTagCons;
      inherit tagAgreeTy tagAgreeProof;
      typeChecks = noError (H.checkHoas foldTy matFoldK);
    };

  # ρ across the extraction boundary: the opaque lambda gives back the
  # Nix function it carries — the live renderer itself. Rendering both
  # sides of the drift check through rhoX keeps the renderer single.
  rhoX = fx.tc.elaborate.verifyAndExtract rhoTy rho;

  # Extracted datatype values are positionally named (con<i> / _field<j>);
  # rename through datatype metadata to declared constructor/field names.
  # Field values stay lazy, so opaque payloads are renamed without force.
  renameByDatatype = dt: s:
    let
      ctors = (fx.tc.generic.datatype.datatypeInfo dt).constructors;
      byCon = builtins.listToAttrs (lib.imap0
        (i: ctor: { name = "con${toString i}"; value = ctor; }) ctors);
      ctor = byCon.${s._con};
    in
    { _con = ctor.name; } // builtins.listToAttrs (lib.imap0
      (i: f: { name = f.name; value = s."_field${toString i}"; }) ctor.fields);

  # Rebuild a renderable step from an extracted one. env (attrs) and the
  # source payload are axiomatised-opaque in the kernel — extraction cannot
  # carry them, so they reattach from the live step (the designed trust
  # boundary). Every ρ-visible representable field (tool.name, args, path,
  # text) comes from the extracted step.
  renderableStep = live: s:
    let named = renameByDatatype mb.descriptions.BuildPlanStep s; in
    if named._con == "runStep" then
      named // {
        tool = renameByDatatype mb.descriptions.FinalizedToolSpec named.tool;
        env = live.env;
      }
    else if named._con == "copyStep" then named // { source = live.source; }
    else named;

  extractedNodeSteps = matFold.matFoldX nodeCompiledOps;
  extractedCSteps = matFold.matFoldX cCompiledOps;
  extractedOciSteps = matFold.matFoldX ociCompiledOps;
  extractedIdlSteps = matFold.matFoldX idlCompiledOps;
  extractedStepCons =
    map (s: (renameByDatatype mb.descriptions.BuildPlanStep s)._con);

  # The extraction drift-check: matFoldK crosses the Pi extraction boundary
  # as a runnable Nix function, consumes the live operations directly, and
  # must reproduce live materialize — same constructor sequence (which pins
  # the length, so the zipped render comparison cannot truncate away extra
  # steps) and same rendered commands through ρ. Both sides render through
  # rhoX, and rhoIsLiveRenderer pins rhoX to the live renderer, so renderer
  # drift is excluded; what remains is genuine fold drift. Step names are
  # ρ-invisible and differ by design; env/source reattach (renderableStep).
  #
  # Coverage split: the constructor-sequence facets cover all four shipped
  # examples; the rendered-command facets apply only to node and c, the
  # examples that render shells.
  extractionCheck =
    let
      renderLive = map mb.program.materialize.renderStep;
      renderX = xs: lives:
        lib.zipListsWith (s: live: rhoX (renderableStep live s)) xs lives;
      checks = {
        nodeNonEmpty = builtins.length extractedNodeSteps > 0;
        ociNonEmpty = builtins.length extractedOciSteps > 0;
        idlNonEmpty = builtins.length extractedIdlSteps > 0;
        hasRunStep = builtins.elem "runStep"
          (extractedStepCons (extractedNodeSteps ++ extractedCSteps));
        nodeCons = extractedStepCons extractedNodeSteps
          == materializeStepCons node.materialize;
        cCons = extractedStepCons extractedCSteps
          == materializeStepCons c.materialize;
        ociCons = extractedStepCons extractedOciSteps
          == materializeStepCons oci.materialize;
        idlCons = extractedStepCons extractedIdlSteps
          == materializeStepCons idl.materialize;
        nodeRender = renderX extractedNodeSteps node.materialize.plan.steps
          == renderLive node.materialize.plan.steps;
        cRender = renderX extractedCSteps c.materialize.plan.steps
          == renderLive c.materialize.plan.steps;
        rhoIsLiveRenderer =
          let s = builtins.head node.materialize.plan.steps;
          in rhoX s == mb.program.materialize.renderStep s;
      };
    in
    checks // { ok = builtins.all (n: checks.${n}) (builtins.attrNames checks); };

  nodeTools = map (tool: tool.name) node.spec.tools;
  cTools = map (tool: tool.name) c.spec.tools;
  sharedTools = lib.intersectLists nodeTools cTools;

  nodeOutputs = map (output: output.format) node.spec.outputs;
  cOutputs = map (output: output.format) c.spec.outputs;
  sharedOutputFormats = lib.intersectLists nodeOutputs cOutputs;

  stringList = H.listOf H.string;
  nodeToolsH = V.review stringList nodeTools;
  cToolsH = V.review stringList cTools;
  sharedToolsH = V.review stringList sharedTools;
  nodeOutputsH = V.review stringList nodeOutputs;
  cOutputsH = V.review stringList cOutputs;
  sharedOutputFormatsH = V.review stringList sharedOutputFormats;

  intersectByKernel = left: right:
    v.filter H.string
      (v.fn "candidate" H.string
        (candidate: v.strElem candidate right))
      left;

  builderSpecFields =
    map
      (field: field.name)
      ((builtins.head (G.derive.deriveDescriptor BuilderSpec).constructors).fields);

  # dry-run tags every op; materialize records a step only for
  # runTool/writeFile/copyPath. Filtering dry-run to those kinds and renaming
  # reproduces materialize's step constructors in order.
  stepKindToCon = { run = "runStep"; write = "writeStep"; copy = "copyStep"; };
  dryRunStepCons = dry:
    map (s: stepKindToCon.${s.kind})
      (builtins.filter (s: stepKindToCon ? ${s.kind}) dry.steps);
  materializeStepCons = mat: map (s: s._con) mat.plan.steps;
  stepConToTag = { runStep = "RunT"; writeStep = "WriteT"; copyStep = "CopyT"; mkdirStep = "MkdirT"; };

  theoremList = [
    (kernelCheck {
      name = "node-spec-inhabits-node-ornament";
      statement = phrase "node.spec : NodeServiceBuilder.T"
        "\\mathsf{node.spec} : \\mathsf{NodeServiceBuilder.T}";
      type = term "NodeServiceBuilder.T"
        "\\mathsf{NodeServiceBuilder.T}"
        NodeBuilder.T;
      proof = term "V.review NodeServiceBuilder.T node.spec"
        "\\mathsf{review}_{\\mathsf{NodeServiceBuilder.T}}(\\mathsf{node.spec})"
        nodeSpecH;
    })
    (kernelCheck {
      name = "c-spec-inhabits-c-ornament";
      statement = phrase "c.spec : CCodegenBuilder.T"
        "\\mathsf{c.spec} : \\mathsf{CCodegenBuilder.T}";
      type = term "CCodegenBuilder.T"
        "\\mathsf{CCodegenBuilder.T}"
        CBuilder.T;
      proof = term "V.review CCodegenBuilder.T c.spec"
        "\\mathsf{review}_{\\mathsf{CCodegenBuilder.T}}(\\mathsf{c.spec})"
        cSpecH;
    })
    (kernelCheck {
      name = "node-forget-has-builder-spec-codomain";
      statement = phrase "forget_Node : NodeServiceBuilder.T -> BuilderSpec.T"
        "\\mathsf{forget}_{Node} : \\mathsf{NodeServiceBuilder.T} \\to \\mathsf{BuilderSpec.T}";
      type = term "Pi(spec : NodeServiceBuilder.T). BuilderSpec.T"
        "\\Pi(\\mathsf{spec} : \\mathsf{NodeServiceBuilder.T}).\\, \\mathsf{BuilderSpec.T}"
        (H.forall "spec" NodeBuilder.T (_: BuilderSpec.T));
      proof = term "G.ornaments.forgetHoas NodeServiceBuilder"
        "\\mathsf{forgetHoas}(\\mathsf{NodeServiceBuilder})"
        (G.ornaments.forgetHoas NodeBuilder);
    })
    (kernelCheck {
      name = "c-forget-has-builder-spec-codomain";
      statement = phrase "forget_C : CCodegenBuilder.T -> BuilderSpec.T"
        "\\mathsf{forget}_{C} : \\mathsf{CCodegenBuilder.T} \\to \\mathsf{BuilderSpec.T}";
      type = term "Pi(spec : CCodegenBuilder.T). BuilderSpec.T"
        "\\Pi(\\mathsf{spec} : \\mathsf{CCodegenBuilder.T}).\\, \\mathsf{BuilderSpec.T}"
        (H.forall "spec" CBuilder.T (_: BuilderSpec.T));
      proof = term "G.ornaments.forgetHoas CCodegenBuilder"
        "\\mathsf{forgetHoas}(\\mathsf{CCodegenBuilder})"
        (G.ornaments.forgetHoas CBuilder);
    })
    (kernelCheck {
      name = "node-forget-computes-base-builder-spec";
      statement = phrase "forget_Node node.spec = node.baseSpec : BuilderSpec.T"
        "\\mathsf{forget}_{Node}(\\mathsf{node.spec}) = \\mathsf{node.baseSpec} : \\mathsf{BuilderSpec.T}";
      type = term "Eq BuilderSpec.T (forget_Node node.spec) node.baseSpec"
        "\\operatorname{Eq}_{\\mathsf{BuilderSpec.T}}(\\mathsf{forget}_{Node}(\\mathsf{node.spec}), \\mathsf{node.baseSpec})"
        (H.eq BuilderSpec.T
          (G.ornaments.forget NodeBuilder nodeSpecH)
          nodeBaseSpecH);
      proof = term "H.refl" "\\mathsf{refl}" H.refl;
    })
    (kernelCheck {
      name = "c-forget-computes-base-builder-spec";
      statement = phrase "forget_C c.spec = c.baseSpec : BuilderSpec.T"
        "\\mathsf{forget}_{C}(\\mathsf{c.spec}) = \\mathsf{c.baseSpec} : \\mathsf{BuilderSpec.T}";
      type = term "Eq BuilderSpec.T (forget_C c.spec) c.baseSpec"
        "\\operatorname{Eq}_{\\mathsf{BuilderSpec.T}}(\\mathsf{forget}_{C}(\\mathsf{c.spec}), \\mathsf{c.baseSpec})"
        (H.eq BuilderSpec.T
          (G.ornaments.forget CBuilder cSpecH)
          cBaseSpecH);
      proof = term "H.refl" "\\mathsf{refl}" H.refl;
    })
    (kernelConversion {
      name = "node-program-compilation-factors-through-forget";
      statement = phrase "node.program = fromSpec (forget_Node node.spec)"
        "\\mathsf{program}_{Node} \\equiv \\mathsf{fromSpec}\\big(\\mathsf{forget}_{Node}(\\mathsf{node.spec})\\big)";
      type = phrase "Definitional equality of Free(BuilderEff) programs"
        "\\mathsf{program}_{Node} \\equiv \\mathsf{fromSpec}\\big(\\mathsf{forget}_{Node}(\\mathsf{node.spec})\\big)";
      proof = phrase "C.conv 0 (evalHoas node.program) (evalHoas (fromSpec (forget_Node node.spec)))"
        "\\operatorname{conv}\\big(\\mathsf{program}_{Node},\\ \\mathsf{fromSpec}(\\mathsf{forget}_{Node}(\\mathsf{node.spec}))\\big)";
      lhs = node.program;
      rhs = nodeBaseProgram;
    })
    (kernelConversion {
      name = "c-program-compilation-factors-through-forget";
      statement = phrase "c.program = fromSpec (forget_C c.spec)"
        "\\mathsf{program}_{C} \\equiv \\mathsf{fromSpec}\\big(\\mathsf{forget}_{C}(\\mathsf{c.spec})\\big)";
      type = phrase "Definitional equality of Free(BuilderEff) programs"
        "\\mathsf{program}_{C} \\equiv \\mathsf{fromSpec}\\big(\\mathsf{forget}_{C}(\\mathsf{c.spec})\\big)";
      proof = phrase "C.conv 0 (evalHoas c.program) (evalHoas (fromSpec (forget_C c.spec)))"
        "\\operatorname{conv}\\big(\\mathsf{program}_{C},\\ \\mathsf{fromSpec}(\\mathsf{forget}_{C}(\\mathsf{c.spec}))\\big)";
      lhs = c.program;
      rhs = cBaseProgram;
    })
    (kernelConversion {
      name = "node-program-is-from-ornamented-spec-no-bypass";
      statement = phrase "node.program = fromOrnamentedSpec NodeServiceBuilder.T node.spec"
        "\\mathsf{program}_{Node} \\equiv \\mathsf{fromSpec}(\\mathsf{NodeServiceBuilder.T},\\ \\mathsf{node.spec})";
      type = phrase "Definitional equality of Free(BuilderEff) programs"
        "\\mathsf{program}_{Node} \\equiv \\mathsf{fromSpec}(\\mathsf{NodeServiceBuilder.T},\\ \\mathsf{node.spec})";
      proof = phrase "C.conv 0 (evalHoas node.program) (evalHoas (fromOrnamentedSpec NodeServiceBuilder.T node.spec))"
        "\\operatorname{conv}\\big(\\mathsf{program}_{Node},\\ \\mathsf{fromSpec}(\\mathsf{NodeServiceBuilder.T},\\ \\mathsf{node.spec})\\big)";
      lhs = node.program;
      rhs = nodeFromSpec;
    })
    (kernelConversion {
      name = "c-program-is-from-ornamented-spec-no-bypass";
      statement = phrase "c.program = fromOrnamentedSpec CCodegenBuilder.T c.spec"
        "\\mathsf{program}_{C} \\equiv \\mathsf{fromSpec}(\\mathsf{CCodegenBuilder.T},\\ \\mathsf{c.spec})";
      type = phrase "Definitional equality of Free(BuilderEff) programs"
        "\\mathsf{program}_{C} \\equiv \\mathsf{fromSpec}(\\mathsf{CCodegenBuilder.T},\\ \\mathsf{c.spec})";
      proof = phrase "C.conv 0 (evalHoas c.program) (evalHoas (fromOrnamentedSpec CCodegenBuilder.T c.spec))"
        "\\operatorname{conv}\\big(\\mathsf{program}_{C},\\ \\mathsf{fromSpec}(\\mathsf{CCodegenBuilder.T},\\ \\mathsf{c.spec})\\big)";
      lhs = c.program;
      rhs = cFromSpec;
    })
    (kernelCheck {
      name = "oci-spec-inhabits-oci-ornament";
      statement = phrase "oci.spec : OciImageBuilder.T"
        "\\mathsf{oci.spec} : \\mathsf{OciImageBuilder.T}";
      type = term "OciImageBuilder.T"
        "\\mathsf{OciImageBuilder.T}"
        OciBuilder.T;
      proof = term "V.review OciImageBuilder.T oci.spec"
        "\\mathsf{review}_{\\mathsf{OciImageBuilder.T}}(\\mathsf{oci.spec})"
        ociSpecH;
    })
    (kernelCheck {
      name = "oci-forget-has-builder-spec-codomain";
      statement = phrase "forget_Oci : OciImageBuilder.T -> BuilderSpec.T"
        "\\mathsf{forget}_{Oci} : \\mathsf{OciImageBuilder.T} \\to \\mathsf{BuilderSpec.T}";
      type = term "Pi(spec : OciImageBuilder.T). BuilderSpec.T"
        "\\Pi(\\mathsf{spec} : \\mathsf{OciImageBuilder.T}).\\, \\mathsf{BuilderSpec.T}"
        (H.forall "spec" OciBuilder.T (_: BuilderSpec.T));
      proof = term "G.ornaments.forgetHoas OciImageBuilder"
        "\\mathsf{forgetHoas}(\\mathsf{OciImageBuilder})"
        (G.ornaments.forgetHoas OciBuilder);
    })
    (kernelCheck {
      name = "oci-forget-computes-base-builder-spec";
      statement = phrase "forget_Oci oci.spec = oci.baseSpec : BuilderSpec.T"
        "\\mathsf{forget}_{Oci}(\\mathsf{oci.spec}) = \\mathsf{oci.baseSpec} : \\mathsf{BuilderSpec.T}";
      type = term "Eq BuilderSpec.T (forget_Oci oci.spec) oci.baseSpec"
        "\\operatorname{Eq}_{\\mathsf{BuilderSpec.T}}(\\mathsf{forget}_{Oci}(\\mathsf{oci.spec}), \\mathsf{oci.baseSpec})"
        (H.eq BuilderSpec.T
          (G.ornaments.forget OciBuilder ociSpecH)
          ociBaseSpecH);
      proof = term "H.refl" "\\mathsf{refl}" H.refl;
    })
    (kernelConversion {
      name = "oci-program-compilation-factors-through-forget";
      statement = phrase "oci.program = fromSpec (forget_Oci oci.spec)"
        "\\mathsf{program}_{Oci} \\equiv \\mathsf{fromSpec}\\big(\\mathsf{forget}_{Oci}(\\mathsf{oci.spec})\\big)";
      type = phrase "Definitional equality of Free(BuilderEff) programs"
        "\\mathsf{program}_{Oci} \\equiv \\mathsf{fromSpec}\\big(\\mathsf{forget}_{Oci}(\\mathsf{oci.spec})\\big)";
      proof = phrase "C.conv 0 (evalHoas oci.program) (evalHoas (fromSpec (forget_Oci oci.spec)))"
        "\\operatorname{conv}\\big(\\mathsf{program}_{Oci},\\ \\mathsf{fromSpec}(\\mathsf{forget}_{Oci}(\\mathsf{oci.spec}))\\big)";
      lhs = oci.program;
      rhs = ociBaseProgram;
    })
    (kernelConversion {
      name = "oci-program-is-from-ornamented-spec-no-bypass";
      statement = phrase "oci.program = fromOrnamentedSpec OciImageBuilder.T oci.spec"
        "\\mathsf{program}_{Oci} \\equiv \\mathsf{fromSpec}(\\mathsf{OciImageBuilder.T},\\ \\mathsf{oci.spec})";
      type = phrase "Definitional equality of Free(BuilderEff) programs"
        "\\mathsf{program}_{Oci} \\equiv \\mathsf{fromSpec}(\\mathsf{OciImageBuilder.T},\\ \\mathsf{oci.spec})";
      proof = phrase "C.conv 0 (evalHoas oci.program) (evalHoas (fromOrnamentedSpec OciImageBuilder.T oci.spec))"
        "\\operatorname{conv}\\big(\\mathsf{program}_{Oci},\\ \\mathsf{fromSpec}(\\mathsf{OciImageBuilder.T},\\ \\mathsf{oci.spec})\\big)";
      lhs = oci.program;
      rhs = ociFromSpec;
    })
    (kernelCheck {
      name = "idl-spec-inhabits-idl-ornament";
      statement = phrase "idl.spec : IdlBuilder.T"
        "\\mathsf{idl.spec} : \\mathsf{IdlBuilder.T}";
      type = term "IdlBuilder.T"
        "\\mathsf{IdlBuilder.T}"
        IdlBuilder.T;
      proof = term "V.review IdlBuilder.T idl.spec"
        "\\mathsf{review}_{\\mathsf{IdlBuilder.T}}(\\mathsf{idl.spec})"
        idlSpecH;
    })
    (kernelCheck {
      name = "idl-forget-has-code-gen-codomain";
      statement = phrase "forget_Idl : IdlBuilder.T -> CodeGenBuilder.T"
        "\\mathsf{forget}_{Idl} : \\mathsf{IdlBuilder.T} \\to \\mathsf{CodeGenBuilder.T}";
      type = term "Pi(spec : IdlBuilder.T). CodeGenBuilder.T"
        "\\Pi(\\mathsf{spec} : \\mathsf{IdlBuilder.T}).\\, \\mathsf{CodeGenBuilder.T}"
        (H.forall "spec" IdlBuilder.T (_: CodeGenBuilder.T));
      proof = term "G.ornaments.forgetHoas IdlBuilder"
        "\\mathsf{forgetHoas}(\\mathsf{IdlBuilder})"
        (G.ornaments.forgetHoas IdlBuilder);
    })
    (kernelCheck {
      name = "idl-composite-forget-has-builder-spec-codomain";
      statement = phrase "forget_CG . forget_Idl : IdlBuilder.T -> BuilderSpec.T"
        "\\mathsf{forget}_{CG} \\circ \\mathsf{forget}_{Idl} : \\mathsf{IdlBuilder.T} \\to \\mathsf{BuilderSpec.T}";
      type = term "Pi(spec : IdlBuilder.T). BuilderSpec.T"
        "\\Pi(\\mathsf{spec} : \\mathsf{IdlBuilder.T}).\\, \\mathsf{BuilderSpec.T}"
        (H.forall "spec" IdlBuilder.T (_: BuilderSpec.T));
      proof = term "lam spec. forgetHoas CodeGenBuilder (forgetHoas IdlBuilder spec)"
        "\\lambda \\mathsf{spec}.\\, \\mathsf{forgetHoas}(\\mathsf{CodeGenBuilder})\\,(\\mathsf{forgetHoas}(\\mathsf{IdlBuilder})\\,\\mathsf{spec})"
        (H.lam "spec" IdlBuilder.T (s:
          H.app (G.ornaments.forgetHoas CodeGenBuilder)
            (H.app (G.ornaments.forgetHoas IdlBuilder) s)));
    })
    (kernelCheck {
      name = "idl-forget-computes-code-gen-spec";
      statement = phrase "forget_Idl idl.spec = idl.cgSpec : CodeGenBuilder.T"
        "\\mathsf{forget}_{Idl}(\\mathsf{idl.spec}) = \\mathsf{idl.cgSpec} : \\mathsf{CodeGenBuilder.T}";
      type = term "Eq CodeGenBuilder.T (forget_Idl idl.spec) idl.cgSpec"
        "\\operatorname{Eq}_{\\mathsf{CodeGenBuilder.T}}(\\mathsf{forget}_{Idl}(\\mathsf{idl.spec}), \\mathsf{idl.cgSpec})"
        (H.eq CodeGenBuilder.T
          (G.ornaments.forget IdlBuilder idlSpecH)
          idlCgSpecH);
      proof = term "H.refl" "\\mathsf{refl}" H.refl;
    })
    (kernelCheck {
      name = "idl-forget-computes-base-builder-spec";
      statement = phrase "forget_CG (forget_Idl idl.spec) = idl.baseSpec : BuilderSpec.T"
        "\\mathsf{forget}_{CG}(\\mathsf{forget}_{Idl}(\\mathsf{idl.spec})) = \\mathsf{idl.baseSpec} : \\mathsf{BuilderSpec.T}";
      type = term "Eq BuilderSpec.T (forget_CG (forget_Idl idl.spec)) idl.baseSpec"
        "\\operatorname{Eq}_{\\mathsf{BuilderSpec.T}}(\\mathsf{forget}_{CG}(\\mathsf{forget}_{Idl}(\\mathsf{idl.spec})), \\mathsf{idl.baseSpec})"
        (H.eq BuilderSpec.T
          (G.ornaments.forget CodeGenBuilder (G.ornaments.forget IdlBuilder idlSpecH))
          idlBaseSpecH);
      proof = term "H.refl" "\\mathsf{refl}" H.refl;
    })
    (kernelConversion {
      name = "idl-program-compilation-factors-through-forget";
      statement = phrase "idl.program = fromSpec (forget_CG (forget_Idl idl.spec))"
        "\\mathsf{program}_{Idl} \\equiv \\mathsf{fromSpec}\\big(\\mathsf{forget}_{CG}(\\mathsf{forget}_{Idl}(\\mathsf{idl.spec}))\\big)";
      type = phrase "Definitional equality of Free(BuilderEff) programs"
        "\\mathsf{program}_{Idl} \\equiv \\mathsf{fromSpec}\\big(\\mathsf{forget}_{CG}(\\mathsf{forget}_{Idl}(\\mathsf{idl.spec}))\\big)";
      proof = phrase "C.conv 0 (evalHoas idl.program) (evalHoas (fromSpec (forget_CG (forget_Idl idl.spec))))"
        "\\operatorname{conv}\\big(\\mathsf{program}_{Idl},\\ \\mathsf{fromSpec}(\\mathsf{forget}_{CG}(\\mathsf{forget}_{Idl}(\\mathsf{idl.spec})))\\big)";
      lhs = idl.program;
      rhs = idlBaseProgram;
    })
    (kernelConversion {
      name = "idl-program-is-from-ornamented-spec-no-bypass";
      statement = phrase "idl.program = fromOrnamentedSpec IdlBuilder.T idl.spec"
        "\\mathsf{program}_{Idl} \\equiv \\mathsf{fromSpec}(\\mathsf{IdlBuilder.T},\\ \\mathsf{idl.spec})";
      type = phrase "Definitional equality of Free(BuilderEff) programs"
        "\\mathsf{program}_{Idl} \\equiv \\mathsf{fromSpec}(\\mathsf{IdlBuilder.T},\\ \\mathsf{idl.spec})";
      proof = phrase "C.conv 0 (evalHoas idl.program) (evalHoas (fromOrnamentedSpec IdlBuilder.T idl.spec))"
        "\\operatorname{conv}\\big(\\mathsf{program}_{Idl},\\ \\mathsf{fromSpec}(\\mathsf{IdlBuilder.T},\\ \\mathsf{idl.spec})\\big)";
      lhs = idl.program;
      rhs = idlFromSpec;
    })
    (kernelConversion {
      name = "builder-effect-language-is-builder-plus-runtime";
      statement = phrase "BuilderEff == BuilderOp + RuntimeOp"
        "\\mathsf{BuilderEff} \\equiv \\mathsf{BuilderOp.T} + \\mathsf{RuntimeOp.T}";
      type = phrase "Definitional equality judgment"
        "\\mathsf{BuilderEff} \\equiv \\mathsf{BuilderOp.T} + \\mathsf{RuntimeOp.T}";
      proof = phrase "C.conv 0 (evalHoas mb.program.BuilderEff) (evalHoas (H.sum BuilderOp.T RuntimeOp.T))"
        "\\operatorname{conv}(\\mathsf{BuilderEff}, \\mathsf{BuilderOp.T} + \\mathsf{RuntimeOp.T})";
      lhs = mb.program.BuilderEff;
      rhs = builderEffSum;
    })
    (kernelCheck {
      name = "shared-tools-normalize-from-actual-tool-lists";
      statement = phrase "filter (member c.tools) node.tools = sharedTools"
        "\\operatorname{filter}(\\lambda x.\\, x \\in \\mathsf{c.tools})(\\mathsf{node.tools}) = \\mathsf{sharedTools}";
      type = term "Eq (List String) (filter (member c.tools) node.tools) sharedTools"
        "\\operatorname{Eq}_{\\operatorname{List}(\\mathsf{String})}(\\operatorname{filter}(\\lambda x.\\, x \\in \\mathsf{c.tools})(\\mathsf{node.tools}), \\mathsf{sharedTools})"
        (H.eq stringList
          (intersectByKernel nodeToolsH cToolsH)
          sharedToolsH);
      proof = term "H.refl" "\\mathsf{refl}" H.refl;
    })
    (kernelCheck {
      name = "shared-output-formats-normalize-from-actual-output-lists";
      statement = phrase "filter (member c.outputFormats) node.outputFormats = sharedOutputFormats"
        "\\operatorname{filter}(\\lambda x.\\, x \\in \\mathsf{c.outputFormats})(\\mathsf{node.outputFormats}) = \\mathsf{sharedOutputFormats}";
      type = term "Eq (List String) (filter (member c.outputFormats) node.outputFormats) sharedOutputFormats"
        "\\operatorname{Eq}_{\\operatorname{List}(\\mathsf{String})}(\\operatorname{filter}(\\lambda x.\\, x \\in \\mathsf{c.outputFormats})(\\mathsf{node.outputFormats}), \\mathsf{sharedOutputFormats})"
        (H.eq stringList
          (intersectByKernel nodeOutputsH cOutputsH)
          sharedOutputFormatsH);
      proof = term "H.refl" "\\mathsf{refl}" H.refl;
    })
    (kernelCheck {
      name = "matfoldk-internalizes-materialize-step-emission";
      statement = phrase "matFoldK : listOf BuilderEff → listOf BuildPlanStep"
        "\\mathsf{matFoldK} : \\operatorname{List}(\\mathsf{BuilderEff}) \\to \\operatorname{List}(\\mathsf{BuildPlanStep})";
      type = term "H.forall _ (listOf BuilderEff) (_: listOf BuildPlanStep.T)"
        "\\Pi(\\_ : \\operatorname{List}(\\mathsf{BuilderEff})).\\, \\operatorname{List}(\\mathsf{BuildPlanStep})"
        matFold.foldTy;
      proof = term "v.fold over v.matchSum → v.matchData per-op step emitters"
        "\\operatorname{fold}(\\operatorname{matchSum}\\,(\\operatorname{matchData}\\,\\mathsf{BuilderOp})\\,(\\operatorname{matchData}\\,\\mathsf{RuntimeOp}))"
        matFold.matFoldK;
    })
    (kernelCheck {
      name = "mattagfoldk-projects-step-fold-to-tags";
      statement = phrase "matTagFoldK : listOf BuilderEff → listOf StepTag"
        "\\mathsf{matTagFoldK} : \\operatorname{List}(\\mathsf{BuilderEff}) \\to \\operatorname{List}(\\mathsf{StepTag})";
      type = term "H.forall _ (listOf BuilderEff) (_: listOf StepTag.T)"
        "\\Pi(\\_ : \\operatorname{List}(\\mathsf{BuilderEff})).\\, \\operatorname{List}(\\mathsf{StepTag})"
        matFold.tagFoldTy;
      proof = term "v.map tagOf ∘ matFoldK"
        "\\operatorname{map}\\,\\mathsf{tagOf} \\circ \\mathsf{matFoldK}"
        matFold.matTagFoldK;
    })
    (kernelCheck {
      name = "drytagfoldk-internalizes-dryrun-tag-emission";
      statement = phrase "dryTagFoldK : listOf BuilderEff → listOf StepTag"
        "\\mathsf{dryTagFoldK} : \\operatorname{List}(\\mathsf{BuilderEff}) \\to \\operatorname{List}(\\mathsf{StepTag})";
      type = term "H.forall _ (listOf BuilderEff) (_: listOf StepTag.T)"
        "\\Pi(\\_ : \\operatorname{List}(\\mathsf{BuilderEff})).\\, \\operatorname{List}(\\mathsf{StepTag})"
        matFold.tagFoldTy;
      proof = term "v.fold over per-op {run,write,copy} tag emitters"
        "\\operatorname{fold}(\\operatorname{matchSum}\\,(\\operatorname{matchData}\\,\\mathsf{BuilderOp}\\to\\mathsf{StepTag}))"
        matFold.dryTagFoldK;
    })
    (kernelCheck {
      name = "mattagfoldk-agrees-with-drytagfoldk-forall-p";
      heavy = true;
      statement = phrase "∀p. matTagFoldK p = dryTagFoldK p : listOf StepTag"
        "\\forall p.\\ \\mathsf{matTagFoldK}\\,p = \\mathsf{dryTagFoldK}\\,p : \\operatorname{List}(\\mathsf{StepTag})";
      type = term "∀p:listOf BuilderEff. Eq (listOf StepTag) (matTagFoldK p) (dryTagFoldK p)"
        "\\Pi(p:\\operatorname{List}(\\mathsf{BuilderEff})).\\,\\operatorname{Eq}(\\mathsf{matTagFoldK}\\,p,\\ \\mathsf{dryTagFoldK}\\,p)"
        matFold.tagAgreeTy;
      proof = term "listElim induction; cons-head case-split; J-congruence on emitting ctors, ih on the rest"
        "\\mathsf{listElim}\\,(\\mathsf{sumElim}\\,(\\mathsf{elimData}\\,\\mathsf{J}/\\mathsf{ih}))"
        matFold.tagAgreeProof;
    })
  ];

  normalForms = {
    inherit builderSpecFields sharedTools sharedOutputFormats;
    node = {
      name = node.spec.name;
      baseName = nodeBaseSpec.name;
      tools = nodeTools;
      outputFormats = nodeOutputs;
      baseFields = builtins.attrNames nodeBaseSpec;
    };
    c = {
      name = c.spec.name;
      baseName = cBaseSpec.name;
      tools = cTools;
      outputFormats = cOutputs;
      baseFields = builtins.attrNames cBaseSpec;
    };
  };

  value = {
    inherit theoremList normalForms planStep rhoCheck extractionCheck;
  };

in
{
  scope.bridgeModel = {
    inherit value;

    # One test per theorem: streaming results, failures name the theorem.
    tests = builtins.listToAttrs
      (map
        (theorem: {
          name = "${lib.optionalString (theorem.heavy or false) "heavy-"}bridge-theorem-${theorem.name}";
          value = { expr = theorem.ok; expected = true; };
        })
        theoremList)
    // {
      "bridge-base-field-normal-forms-match-builder-spec" = {
        expr =
          let expected = builtins.sort builtins.lessThan ([ "_con" ] ++ builderSpecFields);
          in value.normalForms.node.baseFields == expected
          && value.normalForms.c.baseFields == expected;
        expected = true;
      };

      "bridge-shared-tools-are-derived-from-actual-specs" = {
        expr = value.normalForms.sharedTools == lib.intersectLists nodeTools cTools;
        expected = true;
      };

      "bridge-shared-output-formats-are-derived-from-actual-specs" = {
        expr = value.normalForms.sharedOutputFormats == lib.intersectLists nodeOutputs cOutputs;
        expected = true;
      };

      "bridge-examples-build-operations-without-bypass" = {
        expr = builtins.all (src: !lib.hasInfix "operations ++" src) [
          (builtins.readFile ./node-service/builder.nix)
          (builtins.readFile ./c-codegen/builder.nix)
          (builtins.readFile ./oci-image/builder.nix)
          (builtins.readFile ./idl/builder.nix)
        ];
        expected = true;
      };

      # dry-run is a separately written fold that never calls materialize, so
      # agreement of their step constructors is genuine cross-interpreter
      # content a refactor can break. Non-vacuity guards against empty steps.
      "bridge-dry-run-and-materialize-step-constructors-agree" = {
        expr = {
          nodeNonEmpty = builtins.length node.materialize.plan.steps > 0;
          cNonEmpty = builtins.length c.materialize.plan.steps > 0;
          nodeCons = dryRunStepCons node.dryRun == materializeStepCons node.materialize;
          cCons = dryRunStepCons c.dryRun == materializeStepCons c.materialize;
        };
        expected = {
          nodeNonEmpty = true;
          cNonEmpty = true;
          nodeCons = true;
          cCons = true;
        };
      };

      # The tag projection of matFoldK agrees with the dry-run tag fold on
      # both examples (structural agreement), and both reproduce the tags of
      # live materialize's emitted step constructors. The kernel theorem
      # mattagfoldk-agrees-with-drytagfoldk-forall-p proves the agreement
      # ∀p; this gates the two concrete instances. heavy: each fold
      # application runs verifyAndExtract (typecheck + kernel normalization)
      # over a full example op list.
      "heavy-bridge-matfoldk-tag-fold-agrees-with-dryrun" = {
        expr =
          let toTags = mat: map (con: stepConToTag.${con}) (materializeStepCons mat);
          in {
            nodeNonEmpty = builtins.length (matFold.matTagCons matFold.nodeOpsH) > 0;
            nodeAgree = matFold.matTagCons matFold.nodeOpsH == matFold.dryTagCons matFold.nodeOpsH;
            cAgree = matFold.matTagCons matFold.cOpsH == matFold.dryTagCons matFold.cOpsH;
            nodeFaithful = matFold.matTagCons matFold.nodeOpsH == toTags node.materialize;
            cFaithful = matFold.matTagCons matFold.cOpsH == toTags c.materialize;
          };
        expected = {
          nodeNonEmpty = true;
          nodeAgree = true;
          cAgree = true;
          nodeFaithful = true;
          cFaithful = true;
        };
      };

      # BuildPlanStep.T is the kernel carrier for the structural step-fold,
      # reused directly from descriptions.nix. This gates that the carrier forms
      # (BuildPlanStep.T : U0) and that its emitting constructors inhabit with
      # payloads threaded as eliminator-bound variables — exactly matFoldK's
      # usage — plus the param-instantiated args : listOf string field.
      "bridge-buildplanstep-carrier-inhabits-under-threading" = {
        expr = value.planStep;
        expected = {
          typeForms = true;
          runStepThreads = true;
          runStepLitArgs = true;
          writeStepInhabits = true;
          copyStepThreads = true;
          ok = true;
        };
      };

      # ρ is the renderer the coherence theorem applies to both step-folds. It
      # wraps the live renderStep as an opaque kernel lambda; this gates that it
      # checks against its declared type BuildPlanStep → String.
      "bridge-rho-renderer-typechecks-against-buildplanstep-to-string" = {
        expr = value.rhoCheck;
        expected = { typeChecks = true; ok = true; };
      };
    }
    # One test per extraction drift-check facet; see extractionCheck.
    // builtins.listToAttrs
      (map
        (facet: {
          name = "bridge-extraction-${facet}";
          value = { expr = value.extractionCheck.${facet}; expected = true; };
        })
        [
          "nodeNonEmpty"
          "ociNonEmpty"
          "idlNonEmpty"
          "hasRunStep"
          "nodeCons"
          "cCons"
          "ociCons"
          "idlCons"
          "nodeRender"
          "cRender"
          "rhoIsLiveRenderer"
        ]);
  };
}
