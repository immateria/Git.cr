Repository: /workspace/work/git-eol-workflows/foundation
Base: 1ff359874fc931f33d53aa5fb22fc4913e1fa62b
Head: 8d6309702ea47693f837d4be44fc090f43d49f78

## Commits

8d63097 Allow explicit index fallback for partial attribute maps
e2195ca Add shared canonical-to-worktree EOL workflow helpers

## Stat

 spec/eol_workflow_support_spec.cr   | 307 ++++++++++++++++++++++++++++++++++++
 src/git.cr                          |   1 +
 src/git/conversion.cr               |   2 +
 src/git/conversion/attributes.cr    |  18 ++-
 src/git/conversion/workflows.cr     | 106 +++++++++++++
 src/git/merge/three_way/recovery.cr |   5 +-
 src/git/workflow/hard_reset.cr      |  27 ++--
 7 files changed, 451 insertions(+), 15 deletions(-)

## Diff

diff --git a/spec/eol_workflow_support_spec.cr b/spec/eol_workflow_support_spec.cr
new file mode 100644
index 0000000..20d6ba3
--- /dev/null
+++ b/spec/eol_workflow_support_spec.cr
@@ -0,0 +1,307 @@
+require "spec"
+require "file_utils"
+require "../src/git"
+require "./support/git_oracle"
+
+module EolWorkflowSupport
+  def self.commit(repository : Git::Repository, text : String, attrs : String?, parents = [] of String) : String
+    entries = [Git::Tree::Entry.new("file.txt", "100644", repository.write_blob(text))]
+    entries << Git::Tree::Entry.new(".gitattributes", "100644", repository.write_blob(attrs)) if attrs
+    signature = Git::Signature.new("EOL Workflows", "eol@example.invalid", 1_700_000_000_i64, 0)
+    repository.write_commit(tree: repository.write_tree(entries), parents: parents,
+      author: signature, committer: signature, message: "fixture")
+  end
+
+  def self.pair(root : String, *, same : Bool = false, target_attributes : String = "*.txt text eol=lf\n") : {Git::Repository, String, String}
+    repository = Git::Repository.new(root)
+    first = commit(repository, "first\n", "*.txt text eol=crlf\n")
+    tip = commit(repository, same ? "first\n" : "second\n", target_attributes, [first])
+    repository.refs.update("refs/heads/main", first, expected_oid: nil)
+    repository.refs.update("refs/heads/topic", tip, expected_oid: nil)
+    repository.stage_blob("file.txt", "first\n")
+    repository.stage_blob(".gitattributes", "*.txt text eol=crlf\n")
+    File.write(File.join(root, "file.txt"), "first\r\n")
+    File.write(File.join(root, ".gitattributes"), "*.txt text eol=crlf\n")
+    {repository, first, tip}
+  end
+end
+
+describe "shared EOL workflow support" do
+  ["sha1", "sha256"].each do |format|
+    it "records actual #{format} output bytes while validating canonical receipt IDs" do
+      GitOracle.with_repo(format: format) do |root|
+        repository = Git::Repository.new(root)
+        canonical = repository.write_blob("canonical\n")
+        write = Git::Checkout::Write.new("file.txt", "100644", canonical, "canonical\r\n")
+        raw = Git::Merge::Recovery.encode([] of String, [write], canonical, canonical,
+          repository.object_format, 4096, 10)
+        receipt = Git::Merge::Recovery.decode(raw, canonical, canonical, repository.object_format, 4096, 10)
+        receipt.outputs["file.txt"].oid.should eq(Git::ObjectId.digest("blob", write.data, repository.object_format))
+        expect_raises(Git::Error) do
+          Git::Merge::Recovery.encode([] of String,
+            [Git::Checkout::Write.new("file.txt", "100644", "invalid", write.data)],
+            canonical, canonical, repository.object_format, 4096, 10)
+        end
+      end
+    end
+
+    it "fast-forwards clean #{format} CRLF bytes and materializes target attributes" do
+      GitOracle.with_repo(format: format) do |root|
+        repository, first, tip = EolWorkflowSupport.pair(root)
+        result = repository.fast_forward("topic")
+        result.previous_oid.should eq(first)
+        result.target_oid.should eq(tip)
+        File.read(File.join(root, "file.txt")).should eq("second\n")
+        repository.index_entries.find { |entry| entry.path == "file.txt" }.not_nil!.oid.should eq(repository.write_blob("second\n"))
+        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
+      end
+    end
+
+    it "leaves canonical-unchanged #{format} files alone despite stale stats and new attributes" do
+      GitOracle.with_repo(format: format) do |root|
+        repository, _, _ = EolWorkflowSupport.pair(root, same: true)
+        result = repository.fast_forward("topic")
+        result.changed_paths.should eq([".gitattributes"])
+        File.read(File.join(root, "file.txt")).should eq("first\r\n")
+      end
+    end
+  end
+end
+
+describe "planned workflow conversion" do
+  ["sha1", "sha256"].each do |format|
+    it "projects #{format} ours stages, explicit deletion, and absent-only working attributes" do
+      GitOracle.with_repo(format: format) do |root|
+        repository = Git::Repository.new(root)
+        crlf = repository.write_blob("*.txt text eol=crlf\n")
+        lf = repository.write_blob("*.txt text eol=lf\n")
+        File.write(File.join(root, ".gitattributes"), "*.txt text eol=crlf\n")
+        Dir.mkdir_p(File.join(root, "new"))
+        File.write(File.join(root, "new", ".gitattributes"), "*.txt text eol=crlf\n")
+        current = [Git::Index::Entry.new(".gitattributes", "100644", lf, 0, false, false),
+                   Git::Index::Entry.new("nested/.gitattributes", "100644", lf, 3, false, false),
+                   Git::Index::Entry.new("nested/.gitattributes", "100644", crlf, 2, false, false)]
+        converter = Git::Conversion.for_index(repository, current)
+        converter.checkout("file.txt", "x\n").should eq("x\n")
+        converter.checkout("nested/file.txt", "x\n").should eq("x\r\n")
+        converter.checkout("new/file.txt", "x\n").should eq("x\r\n")
+        converter = Git::Conversion.for_index(repository, current,
+          edits: [Git::Index::Remove.new(".gitattributes"), Git::Index::InvalidateStat.new("nested/.gitattributes")] of Git::Index::Edit)
+        converter.checkout("file.txt", "x\n").should eq("x\n")
+        converter.checkout("nested/file.txt", "x\n").should eq("x\r\n")
+        stages = [Git::Index::Entry.new("new/.gitattributes", "100644", crlf, 3, false, false)]
+        converter = Git::Conversion.for_index(repository, [] of Git::Index::Entry,
+          edits: [Git::Index::PutStages.new("new/.gitattributes", stages),
+                  Git::Index::Put.new(".gitattributes", "120000", crlf)] of Git::Index::Edit)
+        converter.checkout("new/file.txt", "x\n").should eq("x\n")
+        expect_raises(ArgumentError) { Git::Conversion.new(repository, worktree_fallback: true) }
+        expect_raises(ArgumentError) { Git::Attributes.new(repository, worktree_fallback: true) }
+        exact = Git::Conversion.new(repository, attribute_blobs: {} of String => String?)
+        exact.checkout("new/file.txt", "x\n").should eq("x\n")
+      end
+    end
+
+    it "uses actual #{format} marker bytes and final relocated rule paths without publication" do
+      GitOracle.with_repo(format: format) do |root|
+        repository = Git::Repository.new(root)
+        lf = repository.write_blob("*.txt text eol=lf\n")
+        marker = "<<<<<<< ours\n*.txt text eol=lf\n=======\nfile.txt~ours text eol=crlf\n>>>>>>> theirs\n"
+        marker_oid = Git::ObjectId.digest("blob", marker, repository.object_format)
+        expect_raises(Git::Error) { repository.read_object(marker_oid, max_bytes: 4096) }
+        before = Dir.children(root).sort
+        current = [Git::Index::Entry.new("nested/.gitattributes", "100644", lf, 2, false, false)]
+        converter = Git::Conversion.for_index(repository, current,
+          edits: [Git::Index::Put.new("nested/.gitattributes", "100644", lf)] of Git::Index::Edit,
+          writes: [Git::Checkout::Write.new("nested/.gitattributes", "100644", lf, marker)])
+        converter.checkout("nested/file.txt~ours", "x\n").should eq("x\r\n")
+        converter.checkout("nested/file.txt", "x\n").should eq("x\n")
+        repository.read_object(marker_oid, max_bytes: 4096).data.should eq(marker)
+        Dir.children(root).sort.should eq(before)
+        repository.index_entries.should be_empty
+      end
+    end
+
+    it "preserves canonical #{format} write IDs, projects raw states, and keeps symlinks raw" do
+      GitOracle.with_repo(format: format) do |root|
+        repository = Git::Repository.new(root)
+        attrs = repository.write_blob("* text eol=crlf\n")
+        oid = repository.write_blob("x\n")
+        converter = Git::Conversion.new(repository, attribute_blobs: {".gitattributes" => attrs.as(String?)})
+        writes = [Git::Checkout::Write.new("file.txt", "100755", oid, "x\n"),
+                  Git::Checkout::Write.new("link", "120000", oid, "x\n")]
+        output = converter.materialize(writes, max_total_bytes: 5_i64)
+        output[0].should eq(Git::Checkout::Write.new("file.txt", "100755", oid, "x\r\n"))
+        output[1].should eq(writes[1])
+        writes[0].data.should eq("x\n")
+        states = {"file.txt" => Git::Checkout::FileState.new("100755", oid), "link" => Git::Checkout::FileState.new("120000", oid)}
+        raw = converter.raw_states(states, max_total_bytes: 5_i64)
+        raw["file.txt"].should eq(Git::Checkout::FileState.new("100755", Git::ObjectId.digest("blob", "x\r\n", repository.object_format)))
+        raw["link"].should eq(states["link"])
+        states["file.txt"].oid.should eq(oid)
+        expect_raises(Git::Error, /byte budget/) { converter.materialize(writes, max_total_bytes: 4_i64) }
+        expect_raises(Git::Error, /byte budget/) { converter.raw_states(states, max_total_bytes: 4_i64) }
+      end
+    end
+  end
+
+  it "rejects expansion, invalid paths/modes and cancellation before any publication" do
+    GitOracle.with_repo do |root|
+      repository = Git::Repository.new(root)
+      attrs = repository.write_blob("* text eol=crlf\n")
+      oid = repository.write_blob("\n" * 20)
+      blobs = {".gitattributes" => attrs.as(String?)}
+      converter = Git::Conversion.new(repository, attribute_blobs: blobs, max_bytes: 32)
+      write = Git::Checkout::Write.new("file", "100644", oid, "\n" * 20)
+      expect_raises(Git::Error, /byte budget/) { converter.materialize([write], max_total_bytes: 100_i64) }
+      states = {"file" => Git::Checkout::FileState.new("100644", oid)}
+      expect_raises(Git::Error, /byte budget/) { converter.raw_states(states, max_total_bytes: 100_i64) }
+      [Git::Checkout::Write.new("../escape", "100644", oid, "x"),
+       Git::Checkout::Write.new("file", "160000", oid, "x")].each do |invalid|
+        expect_raises(Git::Error) { converter.materialize([invalid], max_total_bytes: 100_i64) }
+        expect_raises(Git::Error) { converter.raw_states({invalid.path => Git::Checkout::FileState.new(invalid.mode, invalid.oid)}, max_total_bytes: 100_i64) }
+      end
+      cancelled = false
+      check = -> { raise Git::Error.new("cancelled") if cancelled }
+      converter = Git::Conversion.new(repository, attribute_blobs: blobs, check: check)
+      cancelled = true
+      expect_raises(Git::Error, "cancelled") { converter.materialize([write], max_total_bytes: 100_i64) }
+      expect_raises(Git::Error, "cancelled") { converter.raw_states(states, max_total_bytes: 100_i64) }
+      expect_raises(Git::Error, "cancelled") { Git::Conversion.for_index(repository, [] of Git::Index::Entry, check: check) }
+      File.exists?(File.join(root, "file")).should be_false
+      repository.index_entries.should be_empty
+    end
+  end
+end
+
+describe "clean-only reset publication" do
+  ["sha1", "sha256"].each do |format|
+    it "expands changed #{format} files using target rules" do
+      GitOracle.with_repo(format: format) do |root|
+        repository, _, tip = EolWorkflowSupport.pair(root, target_attributes: "*.txt text eol=crlf\n")
+        repository.fast_forward("topic").target_oid.should eq(tip)
+        File.read(File.join(root, "file.txt")).should eq("second\r\n")
+        repository.read_head_file("file.txt").should eq("second\n")
+        GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
+      end
+    end
+
+    it "refuses a clean-equivalent #{format} raw race at publication" do
+      GitOracle.with_repo(format: format) do |root|
+        repository, first, _ = EolWorkflowSupport.pair(root, target_attributes: "*.txt text eol=crlf\n")
+        raced = false
+        check = -> do
+          if !raced && File.exists?(File.join(root, ".git", "index.lock"))
+            raced = true
+            File.write(File.join(root, "file.txt"), "first\n")
+          end
+        end
+        expect_raises(Git::Reset::PartialPublication) { repository.fast_forward("topic", check: check) }
+        raced.should be_true
+        repository.head.oid.should eq(first)
+        File.read(File.join(root, "file.txt")).should eq("first\n")
+        File.exists?(File.join(root, ".git", "index.lock")).should be_false
+      end
+    end
+  end
+end
+
+describe "workflow helper bounds" do
+  it "bounds attribute marker writes before interpreting their canonical ID" do
+    GitOracle.with_repo do |root|
+      repository = Git::Repository.new(root)
+      marker = "* text eol=crlf\n" * 4
+      oid = repository.write_blob("* text eol=lf\n")
+      writes = [Git::Checkout::Write.new(".gitattributes", "100644", oid, marker)]
+      expect_raises(Git::Error, /byte budget/) do
+        Git::Conversion.for_index(repository, [] of Git::Index::Entry, writes: writes, max_bytes: 32)
+      end
+      File.exists?(File.join(root, ".gitattributes")).should be_false
+      repository.index_entries.should be_empty
+    end
+  end
+
+  it "bounds canonical reads and raw symlink bytes and propagates operation labels" do
+    GitOracle.with_repo do |root|
+      repository = Git::Repository.new(root)
+      oid = repository.write_blob("12345")
+      converter = Git::Conversion.new(repository, attribute_blobs: {} of String => String?, max_bytes: 4)
+      link = Git::Checkout::Write.new("link", "120000", oid, "12345")
+      expect_raises(Git::Error, /byte budget/) { converter.materialize([link], max_total_bytes: 10_i64) }
+      converter = Git::Conversion.new(repository, attribute_blobs: {} of String => String?)
+      states = {"file" => Git::Checkout::FileState.new("100644", oid)}
+      expect_raises(Git::Error, /test restore total read byte budget/) do
+        converter.raw_states(states, max_total_bytes: 4_i64, operation: "test restore")
+      end
+      expect_raises(Git::Error, /test restore total byte budget/) do
+        converter.materialize([link], max_total_bytes: 4_i64, operation: "test restore")
+      end
+    end
+  end
+end
+
+describe "partial attribute map source policy" do
+  ["sha1", "sha256"].each do |format|
+    it "uses secure working then index fallback only for absent #{format} map keys" do
+      GitOracle.with_repo(format: format) do |root|
+        repository = Git::Repository.new(root)
+        repository.stage_blob(".gitattributes", "*.txt text eol=crlf\n")
+        empty = {} of String => String?
+        converter = Git::Conversion.new(repository, attribute_blobs: empty,
+          worktree_fallback: true, worktree_index_fallback: true)
+        converter.checkout("file.txt", "x\n").should eq("x\r\n")
+        # The default map and planned-index source stay exact; a current index
+        # outside the supplied projection is not an implicit source.
+        Git::Conversion.new(repository, attribute_blobs: empty).checkout("file.txt", "x\n").should eq("x\n")
+        Git::Conversion.new(repository, attribute_blobs: empty, worktree_fallback: true).checkout("file.txt", "x\n").should eq("x\n")
+        Git::Conversion.for_index(repository, [] of Git::Index::Entry).checkout("file.txt", "x\n").should eq("x\n")
+        File.write(File.join(root, ".gitattributes"), "*.txt text eol=lf\n")
+        converter = Git::Conversion.new(repository, attribute_blobs: empty,
+          worktree_fallback: true, worktree_index_fallback: true)
+        converter.checkout("file.txt", "x\n").should eq("x\n")
+        File.write(File.join(root, ".gitattributes"), "*.txt text eol=crlf\n")
+        converter = Git::Conversion.new(repository, attribute_blobs: {".gitattributes" => nil.as(String?)},
+          worktree_fallback: true, worktree_index_fallback: true)
+        converter.checkout("file.txt", "x\n").should eq("x\n")
+        # A present blob also wins over both fallback sources.
+        lf = repository.write_blob("*.txt text eol=lf\n")
+        converter = Git::Conversion.new(repository, attribute_blobs: {".gitattributes" => lf.as(String?)},
+          worktree_fallback: true, worktree_index_fallback: true)
+        converter.checkout("file.txt", "x\n").should eq("x\n")
+      end
+    end
+  end
+
+  it "rejects index fallback without both a blob map and working fallback" do
+    GitOracle.with_repo do |root|
+      repository = Git::Repository.new(root)
+      expect_raises(ArgumentError) { Git::Conversion.new(repository, worktree_index_fallback: true) }
+      expect_raises(ArgumentError) { Git::Conversion.new(repository, worktree_fallback: true, worktree_index_fallback: true) }
+      expect_raises(ArgumentError) do
+        Git::Conversion.new(repository, attribute_blobs: {} of String => String?, worktree_index_fallback: true)
+      end
+      expect_raises(ArgumentError) { Git::Attributes.new(repository, worktree_index_fallback: true) }
+      expect_raises(ArgumentError) { Git::Attributes.new(repository, worktree_fallback: true, worktree_index_fallback: true) }
+      expect_raises(ArgumentError) do
+        Git::Attributes.new(repository, attribute_blobs: {} of String => String?, worktree_index_fallback: true)
+      end
+    end
+  end
+end
+
+describe "fully reserved workflow output budget" do
+  it "accepts empty writes and states at zero budget and refuses nonempty output" do
+    GitOracle.with_repo do |root|
+      repository = Git::Repository.new(root)
+      converter = Git::Conversion.new(repository, attribute_blobs: {} of String => String?)
+      converter.materialize([] of Git::Checkout::Write, max_total_bytes: 0_i64).should be_empty
+      converter.raw_states({} of String => Git::Checkout::FileState, max_total_bytes: 0_i64).should be_empty
+      oid = repository.write_blob("x")
+      expect_raises(Git::Error, /byte budget/) do
+        converter.materialize([Git::Checkout::Write.new("file", "100644", oid, "x")], max_total_bytes: 0_i64)
+      end
+      expect_raises(Git::Error, /byte budget/) do
+        converter.raw_states({"file" => Git::Checkout::FileState.new("100644", oid)}, max_total_bytes: 0_i64)
+      end
+    end
+  end
+end
diff --git a/src/git.cr b/src/git.cr
index 36904c2..859a069 100644
--- a/src/git.cr
+++ b/src/git.cr
@@ -43,24 +43,25 @@ require "./git/references/branches"
 require "./git/references/tags"
 require "./git/workflow/checkout"
 require "./git/index/core"
 require "./git/index/writer"
 require "./git/index/tree"
 require "./git/index/restore"
 require "./git/workflow/reset"
 require "./git/workflow/hard_reset"
 require "./git/merge/fast_forward"
 require "./git/merge/text"
 require "./git/merge/three_way"
 require "./git/merge/plan"
+require "./git/conversion/workflows"
 require "./git/merge"
 require "./git/workflow/sequencer"
 require "./git/workflow/rebase"
 require "./git/workflow/stash"
 require "./git/working_tree/ignore"
 require "./git/working_tree/files"
 require "./git/working_tree/core"
 require "./git/working_tree/stage"
 require "./git/working_tree/remove"
 require "./git/diff"
 require "./git/tree_diff"
 require "./git/patch"
diff --git a/src/git/conversion.cr b/src/git/conversion.cr
index 6f9ed7f..a5084cf 100644
--- a/src/git/conversion.cr
+++ b/src/git/conversion.cr
@@ -41,24 +41,25 @@ module Git
     @warned = Set(String).new
     @attributes : Attributes
     @auto_crlf : AutoCRLF
     @default_crlf : Bool
     @safe_crlf : Bool
     @warn_crlf : Bool
     @index_oids : Hash(String, String)?
     @indexed_crlf = {} of String => Bool
 
     def initialize(@repository : Repository, *, config : Config? = nil,
                    attribute_tree : String? = nil,
                    attribute_blobs : Hash(String, String?)? = nil,
+                   worktree_fallback : Bool = false, worktree_index_fallback : Bool = false,
                    @max_bytes : Int32 = 8_388_608,
                    @max_index_bytes : Int32 = 8_388_608,
                    @warning : Proc(String, Nil)? = nil, @check : Proc(Nil)? = nil)
       raise ArgumentError.new("invalid Git conversion byte budget") if @max_bytes < 1
       raise ArgumentError.new("invalid Git conversion index byte budget") if @max_index_bytes < 128
       @config = config || @repository.config
       @auto_crlf = if @config.value?("core.autocrlf").try(&.downcase) == "input"
                      AutoCRLF::Input
                    elsif @config.boolean?("core.autocrlf") == true
                      AutoCRLF::True
                    else
                      AutoCRLF::False
@@ -69,24 +70,25 @@ module Git
                       when AutoCRLF::Input then false
                       else
                         case @config.value?("core.eol").try(&.downcase)
                         when "crlf" then true
                         when "lf"   then false
                         else             native_crlf
                         end
                       end
       @warn_crlf = @config.value?("core.safecrlf").try(&.downcase) == "warn"
       @safe_crlf = !@warn_crlf && @config.boolean?("core.safecrlf") == true
       @attributes = Attributes.new(@repository, config: @config,
         attribute_tree: attribute_tree, attribute_blobs: attribute_blobs,
+        worktree_fallback: worktree_fallback, worktree_index_fallback: worktree_index_fallback,
         max_bytes: @max_bytes, max_index_bytes: @max_index_bytes, check: @check)
     end
 
     # safe enables the safecrlf round-trip check for writes to the index.
     # Status and diff leave it disabled. Auto mode preserves existing CRLF
     # blobs unless the caller explicitly requests renormalization.
     def clean(path : String, data : String, *, index_oid : String? = nil,
               safe : Bool = false, renormalize : Bool = false) : String
       validate_size!(data.bytesize)
       chosen = action(path)
       return data if chosen.binary? || data.empty?
       stats = gather_stats(data)
diff --git a/src/git/conversion/attributes.cr b/src/git/conversion/attributes.cr
index 60f743c..d4e2aed 100644
--- a/src/git/conversion/attributes.cr
+++ b/src/git/conversion/attributes.cr
@@ -15,34 +15,40 @@ module Git
       pattern : Array(Ignore::Token), tokens : Array(Token)
 
     @rules = {} of String => Array(Rule)
     @macros = {} of String => Array(Token)
     @index_blobs : Hash(String, String)?
     @trees = {} of String => Hash(String, {String, String})
     @tree_bytes = 0_i64
     @bytes_read = 0_i64
     @rule_count = 0
     @global : Array(Rule)
     @info : Array(Rule)
 
-    # A non-nil blob map is the complete selected attribute source; nil
-    # entries are deletions. It never falls back to working/index attrs.
+    # A blob map is authoritative for all present keys, including nil
+    # deletions. Opt-in fallback reads working attrs only for absent keys;
+    # partial maps may also opt into the index when working attrs are absent.
     def initialize(@repository : Repository, *, config : Config? = nil,
                    @attribute_tree : String? = nil,
                    @attribute_blobs : Hash(String, String?)? = nil,
+                   @worktree_fallback : Bool = false, @worktree_index_fallback : Bool = false,
                    @max_bytes : Int32 = 8_388_608,
                    @max_index_bytes : Int32 = 8_388_608, @check : Proc(Nil)? = nil)
       raise ArgumentError.new("invalid Git attribute byte budget") if @max_bytes < 1
       raise ArgumentError.new("invalid Git attribute index byte budget") if @max_index_bytes < 128
       raise ArgumentError.new("conflicting Git attribute sources") if @attribute_tree && @attribute_blobs
+      raise ArgumentError.new("Git attribute worktree fallback requires a blob map") if @worktree_fallback && !@attribute_blobs
+      if @worktree_index_fallback && (!@attribute_blobs || !@worktree_fallback)
+        raise ArgumentError.new("Git attribute index fallback requires a blob map and worktree fallback")
+      end
       @macros["binary"] = [Token.new("diff", Value.new(Kind::Unset)),
                            Token.new("merge", Value.new(Kind::Unset)),
                            Token.new("text", Value.new(Kind::Unset))]
       selected = config || @repository.config
       @global = [] of Rule
       if file = selected.value?("core.attributesfile")
         unless file.empty?
           # Explicit paths only; no ambient HOME expansion.
           full = file.starts_with?('/') ? file : ::File.join(@repository.root, file)
           @global = parse(read_file(full), "", true)
         end
       end
@@ -89,26 +95,30 @@ module Git
       @check.try &.call
       raise Error.new("Git attribute macro depth exceeded") if depth > 64
       values[token.name] = token.value
       if token.value.kind.set? && (expanded = @macros[token.name]?)
         expanded.reverse_each { |part| apply(values, part, depth + 1) }
       end
     end
 
     private def rules_for(directory : String) : Array(Rule)
       @rules[directory] ||= begin
         relative = directory.empty? ? ".gitattributes" : "#{directory}/.gitattributes"
         data = if blobs = @attribute_blobs
-                 oid = blobs[relative]?
-                 oid ? blob(oid) : nil
+                 if blobs.has_key?(relative)
+                   blobs[relative]?.try { |oid| blob(oid) }
+                 elsif @worktree_fallback
+                   working = @repository.work_tree.try { |root| read_file(::File.join(root, relative)) }
+                   working || (@worktree_index_fallback ? index_blobs[relative]?.try { |oid| blob(oid) } : nil)
+                 end
                elsif tree = @attribute_tree
                  tree_attribute(tree, relative)
                else
                  working = @repository.work_tree.try { |root| read_file(::File.join(root, relative)) }
                  working || index_blobs[relative]?.try { |oid| blob(oid) }
                end
         parse(data, directory, directory.empty?)
       end
     end
 
     private def index_blobs : Hash(String, String)
       @index_blobs ||= begin
diff --git a/src/git/conversion/workflows.cr b/src/git/conversion/workflows.cr
new file mode 100644
index 0000000..cc26f81
--- /dev/null
+++ b/src/git/conversion/workflows.cr
@@ -0,0 +1,106 @@
+module Git
+  class Conversion
+    # Project the final index and canonical plan into checkout's index-first
+    # attribute source. Explicitly absent attributes suppress worktree fallback.
+    def self.for_index(repository : Repository, current : Array(Index::Entry), *,
+                       edits : Array(Index::Edit) = [] of Index::Edit,
+                       writes : Array(Checkout::Write) = [] of Checkout::Write,
+                       config : Config? = nil, max_bytes : Int32 = 8_388_608,
+                       max_index_bytes : Int32 = 8_388_608, check : Proc(Nil)? = nil) : Conversion
+      raise ArgumentError.new("invalid Git conversion byte budget") if max_bytes < 1
+      raise ArgumentError.new("invalid Git conversion index byte budget") if max_index_bytes < 128
+      check.try &.call
+      blobs = {} of String => String?
+      stages = {} of String => Int32
+      current.each do |entry|
+        check.try &.call
+        next unless File.basename(entry.path) == ".gitattributes"
+        PathBytes.validate_relative!(entry.path, max_depth: Metadata::MAX_DEPTH)
+        blobs[entry.path] = nil unless blobs.has_key?(entry.path)
+        next unless entry.stage == 0 || entry.stage == 2
+        next if stages[entry.path]? == 0
+        stages[entry.path] = entry.stage
+        blobs[entry.path] = {"100644", "100755"}.includes?(entry.mode) ? entry.oid : nil
+      end
+      edits.each do |edit|
+        check.try &.call
+        next unless File.basename(edit.path) == ".gitattributes"
+        PathBytes.validate_relative!(edit.path, max_depth: Metadata::MAX_DEPTH)
+        case edit
+        when Index::Put
+          blobs[edit.path] = {"100644", "100755"}.includes?(edit.mode) ? edit.oid : nil
+        when Index::Remove
+          blobs[edit.path] = nil
+        when Index::PutStages
+          selected = edit.stages.find { |entry| entry.stage == 0 } || edit.stages.find { |entry| entry.stage == 2 }
+          blobs[edit.path] = selected && {"100644", "100755"}.includes?(selected.mode) ? selected.oid : nil
+        end
+      end
+      bytes = 0_i64
+      writes.each do |write|
+        check.try &.call
+        next unless File.basename(write.path) == ".gitattributes"
+        PathBytes.validate_relative!(write.path, max_depth: Metadata::MAX_DEPTH)
+        if {"100644", "100755"}.includes?(write.mode)
+          # Marker bytes need not match write.oid or exist in the object DB.
+          bytes += write.data.bytesize
+          raise Error.new("Git conversion attribute byte budget exceeded") if bytes > max_bytes
+          blobs[write.path] = repository.write_blob(write.data, max_bytes: max_bytes.to_i64, check: check)
+        else
+          blobs[write.path] = nil
+        end
+      end
+      new(repository, config: config, attribute_blobs: blobs, worktree_fallback: true,
+        max_bytes: max_bytes, max_index_bytes: max_index_bytes, check: check)
+    end
+
+    # Keep object/index identities canonical while preparing all output bytes
+    # before any caller publishes worktree files or operation metadata.
+    def materialize(writes : Array(Checkout::Write), *, max_total_bytes : Int64,
+                    operation : String = "Git checkout") : Array(Checkout::Write)
+      raise ArgumentError.new("invalid #{operation} total byte budget") if max_total_bytes < 0
+      @check.try &.call
+      total = 0_i64
+      writes.map do |write|
+        validate_workflow_file!(write.path, write.mode, write.oid)
+        validate_size!(write.data.bytesize)
+        data = write.mode == "120000" ? write.data : checkout(write.path, write.data)
+        total += data.bytesize
+        raise Error.new("#{operation} total byte budget exceeded") if total > max_total_bytes
+        @check.try &.call
+        Checkout::Write.new(write.path, write.mode, write.oid, data)
+      end
+    end
+
+    # Immutable canonical states become exact raw identities for overwrite and
+    # recovery guards. Read and expanded-output budgets are bounded separately.
+    def raw_states(states : Hash(String, Checkout::FileState), *, max_total_bytes : Int64,
+                   operation : String = "Git checkout") : Hash(String, Checkout::FileState)
+      raise ArgumentError.new("invalid #{operation} total byte budget") if max_total_bytes < 0
+      @check.try &.call
+      reads = 0_i64
+      outputs = 0_i64
+      result = {} of String => Checkout::FileState
+      states.each do |path, state|
+        validate_workflow_file!(path, state.mode, state.oid)
+        kind, bytes = @repository.object(state.oid, @max_bytes) { @check.try &.call }
+        raise Error.new("#{operation} target not a blob") unless kind == "blob"
+        reads += bytes.bytesize
+        raise Error.new("#{operation} total read byte budget exceeded") if reads > max_total_bytes
+        data = state.mode == "120000" ? bytes : checkout(path, bytes)
+        outputs += data.bytesize
+        raise Error.new("#{operation} total byte budget exceeded") if outputs > max_total_bytes
+        @check.try &.call
+        result[path] = Checkout::FileState.new(state.mode, ObjectId.digest("blob", data, @repository.object_format))
+      end
+      result
+    end
+
+    private def validate_workflow_file!(path : String, mode : String, oid : String) : Nil
+      @check.try &.call
+      PathBytes.validate_relative!(path, max_depth: Metadata::MAX_DEPTH)
+      raise Error.new("unsupported Git conversion file mode") unless {"100644", "100755", "120000"}.includes?(mode)
+      ObjectId.valid!(oid, @repository.object_format)
+    end
+  end
+end
diff --git a/src/git/merge/three_way/recovery.cr b/src/git/merge/three_way/recovery.cr
index 1427945..44ffdb9 100644
--- a/src/git/merge/three_way/recovery.cr
+++ b/src/git/merge/three_way/recovery.cr
@@ -26,25 +26,28 @@ module Git
         end
 
         def transition_directories(goals : Array(String)) : Array(String)
           directories.select do |directory|
             goals.any? { |path| directory == path || directory.starts_with?(path + "/") }
           end.to_a.sort_by { |path| {-path.count('/'), -path.bytesize, path} }
         end
       end
 
       def self.encode(paths : Array(String), writes : Array(Checkout::Write), ours : String, theirs : String,
                       format : ObjectId::Format, max_bytes : Int32, max_entries : Int32) : String
         fields = [ours, theirs, paths.size.to_s, writes.size.to_s] + paths
-        writes.each { |write| fields.concat([write.path, write.mode, write.oid]) }
+        writes.each do |write|
+          ObjectId.valid!(write.oid, format)
+          fields.concat([write.path, write.mode, ObjectId.digest("blob", write.data, format)])
+        end
         raw = MAGIC + fields.join('\0')
         decode(raw, ours, theirs, format, max_bytes, max_entries)
         raw
       end
 
       def self.decode(raw : String?, ours : String, theirs : String, format : ObjectId::Format,
                       max_bytes : Int32, max_entries : Int32) : Receipt
         raise Error.new("Git worktree recovery metadata budget exceeded") if raw && raw.bytesize > max_bytes
         unless raw && raw.starts_with?(MAGIC)
           paths = Merge.decode_relocations(raw)
           raise Error.new("Git worktree recovery path budget exceeded") if paths.size > max_entries
           return Receipt.new(paths, {} of String => Checkout::FileState)
diff --git a/src/git/workflow/hard_reset.cr b/src/git/workflow/hard_reset.cr
index d34c914..ac0a6cb 100644
--- a/src/git/workflow/hard_reset.cr
+++ b/src/git/workflow/hard_reset.cr
@@ -27,39 +27,42 @@ module Git
       unless previous && (reference.nil? || reference.starts_with?("refs/heads/"))
         raise Error.new("Git hard reset requires an existing branch or detached HEAD")
       end
       target = History.resolve_commit(self, source, max_object_bytes, check)
       old_tree = read_commit(previous, max_bytes: max_object_bytes, check: check).tree
       target_tree = read_commit(target, max_bytes: max_object_bytes, check: check).tree
       old = Checkout.tree_files(self, old_tree, max_object_bytes: max_object_bytes,
         max_files: max_entries, check: check)
       desired = Checkout.tree_files(self, target_tree, max_object_bytes: max_object_bytes,
         max_files: max_entries, check: check)
       index = @index.entries(max_index_bytes) { check.try &.call }
       raise Error.new("Git hard reset index entry budget exceeded") if index.size > max_entries
-      target_conversion = unless clean_only
-        Conversion.new(self, config: config, attribute_tree: target_tree,
-          max_bytes: max_object_bytes, max_index_bytes: max_index_bytes, check: check)
-      end
+      selected_config = config || self.config
+      target_conversion = Conversion.new(self, config: selected_config, attribute_tree: target_tree,
+        max_bytes: max_object_bytes, max_index_bytes: max_index_bytes, check: check)
+      source_conversion = if clean_only
+                            Conversion.new(self, config: selected_config,
+                              max_bytes: max_object_bytes, max_index_bytes: max_index_bytes, check: check)
+                          end
       index.each do |entry|
         raise Error.new("Git hard reset requires an ordinary resolved index") unless entry.stage == 0 &&
                                                                                      !entry.intent && !entry.skip_worktree && !entry.assume_unchanged &&
                                                                                      {"100644", "100755"}.includes?(entry.mode)
       end
       if clean_only
         raise Error.new("Git clean-only reset requires index equal to HEAD") unless index.size == old.size && index.all? do |entry|
                                                                                       old[entry.path]?.try { |state| state.mode == entry.mode && state.oid == entry.oid } == true
                                                                                     end
         Checkout.require_clean!(self, index, max_blob_bytes: max_object_bytes,
-          max_total_bytes: max_total_bytes, check: check)
+          max_total_bytes: max_total_bytes, check: check, conversion: source_conversion)
       end
       index_by_path = {} of String => Index::Entry
       index.each { |entry| index_by_path[entry.path] = entry }
       index_time = @index.modified_at
       verified = Set(String).new
       tracked = (old.keys + index.map(&.path)).uniq
       Checkout.require_compatible_paths!(tracked, desired.keys)
       names = (tracked + desired.keys).uniq.sort
       raise Error.new("Git hard reset entry budget exceeded") if names.size > max_entries
       edits = IndexRestore.edits(index, IndexRestore.source_entries(self, target_tree,
         max_object_bytes: max_object_bytes, max_entries: max_entries, check: check), nil)
       changed_index_paths = edits.map(&.path)
@@ -68,52 +71,56 @@ module Git
       writes = [] of Checkout::Write
       removals = [] of {String, Checkout::FileState}
       transferred = 0_i64
       names.each do |path|
         check.try &.call
         # Never silently replace a newly tracked path that already exists
         # outside both HEAD and the index, including an ignored file.
         Checkout.require_free_destination!(@root, path) unless tracked.includes?(path)
         absolute = File.join(@root, path)
         indexed = index_by_path[path]?
         stat_clean = indexed ? @worktree.stat_unchanged?(indexed, true, index_time, verified) { check.try &.call } : false
         current = nil.as(Checkout::FileState?)
+        clean_current = nil.as(Checkout::FileState?)
         if tracked.includes?(path)
           parent = @root
           path.split('/')[0...-1].each do |component|
             parent = File.join(parent, component)
             raise Error.new("Git hard reset symlinked parent") if File.symlink?(parent)
             if File.exists?(parent)
               raise Error.new("Git hard reset blocked parent") unless Dir.exists?(parent) && File.realpath(parent) == parent
             end
           end
           raise Error.new("Git hard reset refuses symlinked tracked file") if File.symlink?(absolute)
           if File.exists?(absolute)
             raise Error.new("Git hard reset tracked path is not regular") unless File.file?(absolute)
             mode, data = checkout_working_regular(path, max_object_bytes) { check.try &.call }
             transferred += data.bytesize
             raise Error.new("Git hard reset total byte budget exceeded") if transferred > max_total_bytes
             current = Checkout::FileState.new(mode, ObjectId.digest("blob", data, @object_format))
+            if source_conversion
+              canonical = source_conversion.clean(path, data, index_oid: indexed.try(&.oid))
+              clean_current = Checkout::FileState.new(mode, ObjectId.digest("blob", canonical, @object_format))
+            end
           end
         end
-        if clean_only && old[path]? != current
+        if clean_only && old[path]? != clean_current
           raise Error.new("Git clean-only reset refuses dirty tracked files")
         end
         observed[path] = current
         if goal = desired[path]?
-          next if stat_clean && indexed && goal.mode == indexed.mode && goal.oid == indexed.oid
-          next if clean_only && goal == current
+          next if (clean_only || stat_clean) && indexed && goal.mode == indexed.mode && goal.oid == indexed.oid
           kind, bytes = object(goal.oid, max_object_bytes) { check.try &.call }
           raise Error.new("Git hard reset target not a blob") unless kind == "blob"
-          data = target_conversion ? target_conversion.checkout(path, bytes) : bytes
+          data = target_conversion.checkout(path, bytes)
           transferred += data.bytesize
           raise Error.new("Git hard reset total byte budget exceeded") if transferred > max_total_bytes
           output = Checkout::FileState.new(goal.mode, ObjectId.digest("blob", data, @object_format))
           if !clean_only && indexed && (recorded = indexed.stat) && recorded.size != 0 &&
              recorded.size != data.bytesize && !changed_index_paths.includes?(path)
             # A reset can materialize different EOL bytes for the same blob.
             # Do not retain the old size, or capture a newer unverified stat.
             edits << Index::InvalidateStat.new(path)
           end
           next if output == current
           writes << Checkout::Write.new(path, goal.mode, goal.oid, data)
         elsif actual = current
@@ -131,25 +138,25 @@ module Git
       ref_published = false
       index_published = false
       begin
         locked = admin.open_file("index.lock", LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o666)
         guard = -> do
           check.try &.call
           raise Error.new("Git hard reset HEAD changed") unless head_ref_and_oid == {reference, previous}
           raise Error.new("Git hard reset index changed") unless @index.snapshot_checksum(max_index_bytes) == checksum
         end
         guard.call
         if clean_only
           Checkout.require_clean!(self, index, max_blob_bytes: max_object_bytes,
-            max_total_bytes: max_total_bytes, check: check)
+            max_total_bytes: max_total_bytes, check: check, conversion: source_conversion)
         end
         if prepared = image
           raise Error.new("Git hard reset index image diverged") unless @index.image_state(prepared, max_bytes: max_index_bytes) == :before
           locked.write(prepared.data.to_slice)
           locked.flush
           locked.fsync
         end
         names.each { |path| Checkout.require_free_destination!(@root, path) unless tracked.includes?(path) }
         writes.each_with_index do |write, sequence|
           worktree_started = true
           Checkout.write(@root, write, sequence, expected_old: observed[write.path],
             format: @object_format, check: guard)
