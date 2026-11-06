require "spec"
require "../src/git"
require "./support/blame_oracle"

describe "native Git committed-file blame" do
  ["sha1", "sha256"].each do |format|
    it "attributes #{format} roots and surviving lines through insertion, replacement and deletion" do
      BlameOracle.with_repo(format: format) do |root, repository|
        before = "alpha\nbravo\ncharlie\ndelta\n"
        initial = BlameOracle.commit(repository, "initial", {"file.txt" => before})
        result = BlameOracle.compare(root, repository, "file.txt", initial, before)
        result.map(&.commit_oid).should eq([initial] * 4)
        result.map(&.original_line).should eq([1, 2, 3, 4])
        result.all?(&.boundary?).should be_true
        result[0].author.should eq(Git::Signature.new("Author initial", "author-initial@example.invalid", 1_700_000_000_i64, 330))
        result[0].committer.should eq(Git::Signature.new("Committer initial", "committer-initial@example.invalid", 1_700_000_099_i64, -270))
        after = "inserted\nalpha\nBRAVO\ndelta\n"
        tip = BlameOracle.commit(repository, "edited", {"file.txt" => after}, [initial])
        repository.refs.update("refs/heads/main", tip, expected_oid: nil)
        result = BlameOracle.compare(root, repository, "file.txt", "HEAD", after)
        result.map(&.commit_oid).should eq([tip, initial, tip, initial])
        result.map(&.original_line).should eq([1, 1, 3, 4])
        result.map(&.final_line).should eq([1, 2, 3, 4])
        repository.blame("file.txt").lines.should eq(result.lines)
      end
    end

    it "retains the first matching #{format} line when equal lines are inserted or deleted" do
      BlameOracle.with_repo(format: format) do |root, repository|
        initial = BlameOracle.commit(repository, "duplicate", {"f" => "x\nx\n"})
        tip = BlameOracle.commit(repository, "deleted", {"f" => "x\n"}, [initial])
        result = BlameOracle.compare(root, repository, "f", tip, "x\n")
        result.map { |line| {line.commit_oid, line.original_line} }.should eq([{initial, 1}])
        single = BlameOracle.commit(repository, "single", {"f" => "x\n"})
        inserted = BlameOracle.commit(repository, "inserted", {"f" => "x\nx\n"}, [single])
        result = BlameOracle.compare(root, repository, "f", inserted, "x\nx\n")
        result.map { |line| {line.commit_oid, line.original_line} }.should eq([{single, 1}, {inserted, 2}])
      end
    end

    it "preserves empty, binary, invalid UTF-8 and unterminated #{format} line content" do
      BlameOracle.with_repo(format: format) do |root, repository|
        ["", "\n", "\n\n", "single", "alpha\n\xff\xfe\nlast", "one\0two\nthree\0four", "one\r\ntwo\r\n"].each_with_index do |content, index|
          oid = BlameOracle.commit(repository, "bytes#{index}", {"f" => content})
          result = BlameOracle.compare(root, repository, "f", oid, content)
          GitOracle.assert_bytes!(result.map(&.content).join, content, "blame raw #{format} #{index}")
        end
        initial = BlameOracle.commit(repository, "raw-initial", {"f" => "head\n\xff\0mid\ntail"})
        content = "new\nhead\n\xff\0mid\nTAIL"
        tip = BlameOracle.commit(repository, "raw-edited", {"f" => content}, [initial])
        result = BlameOracle.compare(root, repository, "f", tip, content)
        result.map(&.commit_oid).should eq([tip, initial, initial, tip])
        result[2].content.to_slice.should eq(Bytes[0xff, 0, 109, 105, 100, 10])
        result[3].content.should eq("TAIL")
      end
    end

    it "treats the final LF as part of #{format} line equality" do
      BlameOracle.with_repo(format: format) do |root, repository|
        initial = BlameOracle.commit(repository, "lf-initial", {"f" => "alpha\nbeta\n"})
        removed = BlameOracle.commit(repository, "lf-removed", {"f" => "alpha\nbeta"}, [initial])
        result = BlameOracle.compare(root, repository, "f", removed, "alpha\nbeta")
        result.map(&.commit_oid).should eq([initial, removed])
        result[1].content.should eq("beta")
        added = BlameOracle.commit(repository, "lf-added", {"f" => "alpha\nbeta\n"}, [removed])
        result = BlameOracle.compare(root, repository, "f", added, "alpha\nbeta\n")
        result.map(&.commit_oid).should eq([initial, added])
        result[1].content.should eq("beta\n")
      end
    end

    it "follows exact and 50-percent edited #{format} renames while excluding low similarity and copies" do
      BlameOracle.with_repo(format: format) do |root, repository|
        content = "aaa\nbbb\nccc\nddd\n"
        initial = BlameOracle.commit(repository, "rename-initial", {"old" => content})
        exact = BlameOracle.commit(repository, "rename-exact", {"new" => content}, [initial])
        result = BlameOracle.compare(root, repository, "new", exact, content)
        result.map(&.commit_oid).should eq([initial] * 4)
        result.map(&.original_path).should eq(["old"] * 4)
        result = BlameOracle.compare(root, repository, "new", exact, content, follow_renames: false)
        result.map(&.commit_oid).should eq([exact] * 4)
        half_content = "aaa\nbbb\nCCC\nDDD\n"
        half = BlameOracle.commit(repository, "rename-half", {"new" => half_content}, [initial])
        result = BlameOracle.compare(root, repository, "new", half, half_content)
        result.map(&.commit_oid).should eq([initial, initial, half, half])
        result.map(&.original_path).should eq(["old", "old", "new", "new"])
        low_content = "aaa\nBBB\nCCC\nDDD\n"
        low = BlameOracle.commit(repository, "rename-low", {"new" => low_content}, [initial])
        result = BlameOracle.compare(root, repository, "new", low, low_content)
        result.map(&.commit_oid).should eq([low] * 4)
        copied = BlameOracle.commit(repository, "copied", {"old" => content, "new" => content}, [initial])
        result = BlameOracle.compare(root, repository, "new", copied, content)
        result.map(&.commit_oid).should eq([copied] * 4)
      end
    end

    it "prefers a unique 75-percent #{format} basename rename over a 90-percent other-name candidate" do
      BlameOracle.with_repo(format: format) do |root, repository|
        lines = Array.new(20) { |index| "line%02d\n" % index }
        basename = lines.first(15).join + (15...20).map { |index| "edit%02d\n" % index }.join
        other = lines.first(18).join + (18...20).map { |index| "EDIT%02d\n" % index }.join
        initial = BlameOracle.commit(repository, "basename-initial", {"old/file" => basename, "othername" => other})
        content = lines.join
        tip = BlameOracle.commit(repository, "basename-tip", {"new/file" => content}, [initial])
        result = BlameOracle.compare(root, repository, "new/file", tip, content)
        result.map(&.commit_oid).should eq([initial] * 15 + [tip] * 5)
        result.map(&.original_path).should eq(["old/file"] * 15 + ["new/file"] * 5)
      end
    end

    it "follows a #{format} file renamed over its former containing directory" do
      BlameOracle.with_repo(format: format) do |root, repository|
        initial = BlameOracle.commit(repository, "directory-initial", {"new/source" => "payload\n"})
        tip = BlameOracle.commit(repository, "directory-tip", {"new" => "payload\n"}, [initial])
        result = BlameOracle.compare(root, repository, "new", tip, "payload\n")
        result[0].commit_oid.should eq(initial)
        result[0].original_path.should eq("new/source")
      end
    end

    it "uses #{format} parent order for merge ties and checks whole-blob parent matches first" do
      BlameOracle.with_repo(format: format) do |root, repository|
        base = BlameOracle.commit(repository, "merge-base", {"f" => "base\n"})
        first = BlameOracle.commit(repository, "first", {"f" => "shared\nfirst\n"}, [base], time: 1_700_000_100_i64)
        second = BlameOracle.commit(repository, "second", {"f" => "shared\nsecond\n"}, [base], time: 1_700_000_200_i64)
        third = BlameOracle.commit(repository, "third", {"f" => "shared\nthird\n"}, [base], time: 1_700_000_300_i64)
        content = "shared\nfirst\nsecond\nthird\nmerge-only\n"
        merged = BlameOracle.commit(repository, "merged", {"f" => content}, [first, second, third])
        result = BlameOracle.compare(root, repository, "f", merged, content)
        result.map(&.commit_oid).should eq([first, first, second, third, merged])
        reordered = BlameOracle.commit(repository, "reordered", {"f" => content}, [second, third, first])
        result = BlameOracle.compare(root, repository, "f", reordered, content)
        result.map(&.commit_oid).should eq([second, first, second, third, reordered])
        exact_content = "shared\nsecond\n"
        exact = BlameOracle.commit(repository, "merge-exact", {"f" => exact_content}, [first, second])
        result = BlameOracle.compare(root, repository, "f", exact, exact_content)
        result.map(&.commit_oid).should eq([second, second])
        same = BlameOracle.commit(repository, "same", {"f" => exact_content}, [base])
        identical = BlameOracle.commit(repository, "identical", {"f" => exact_content}, [same, second])
        result = BlameOracle.compare(root, repository, "f", identical, exact_content)
        result.map(&.commit_oid).should eq([same, same])
      end
    end

    it "prefers a same-path #{format} whole-blob parent over an earlier renamed parent" do
      BlameOracle.with_repo(format: format) do |root, repository|
        renamed = BlameOracle.commit(repository, "renamed-parent", {"old" => "same\n"})
        same_path = BlameOracle.commit(repository, "same-path-parent", {"new" => "same\n"})
        merged = BlameOracle.commit(repository, "merge-priority", {"new" => "same\n"}, [renamed, same_path])
        result = BlameOracle.compare(root, repository, "new", merged, "same\n")
        result[0].commit_oid.should eq(same_path)
        result[0].original_path.should eq("new")
      end
    end

    it "limits #{format} blame attribution to the first merge parent when requested" do
      BlameOracle.with_repo(format: format) do |root, repository|
        base = BlameOracle.commit(repository, "base", {"f" => "base\n"})
        first = BlameOracle.commit(repository, "first", {"f" => "shared\nfirst\n"}, [base])
        second = BlameOracle.commit(repository, "second", {"f" => "shared\nsecond\n"}, [base])
        content = "shared\nsecond\n"
        merged = BlameOracle.commit(repository, "merged", {"f" => content}, [first, second])
        result = BlameOracle.compare(root, repository, "f", merged, content, first_parent: true)
        result.map(&.commit_oid).should eq([first, merged])
      end
    end

    it "reads committed #{format} symlink bytes and stops across regular/symlink type changes" do
      BlameOracle.with_repo(format: format) do |root, repository|
        [{"100644", "120000"}, {"120000", "100644"}].each_with_index do |(before_mode, after_mode), index|
          initial = BlameOracle.commit(repository, "kind-initial#{index}", {"f" => "target"}, modes: {"f" => before_mode})
          ["target", "other"].each_with_index do |content, edit|
            tip = BlameOracle.commit(repository, "kind-tip#{index}-#{edit}", {"f" => content}, [initial], modes: {"f" => after_mode})
            result = BlameOracle.compare(root, repository, "f", tip, content)
            result.map(&.commit_oid).should eq([tip])
          end
        end
        File.exists?(File.join(root, "f")).should be_false
      end
    end

    it "resolves explicit #{format} commits, branches and annotated tags independently of HEAD" do
      BlameOracle.with_repo(format: format) do |root, repository|
        old = BlameOracle.commit(repository, "old", {"f" => "before\n"})
        tip = BlameOracle.commit(repository, "tip", {"f" => "after\n"}, [old])
        repository.refs.update("refs/heads/main", tip, expected_oid: nil)
        repository.refs.update("refs/heads/side", old, expected_oid: nil)
        tag = repository.write_tag(object: old, type: Git::ObjectType::Commit, name: "saved", message: "saved\n")
        repository.refs.update("refs/tags/saved", tag, expected_oid: nil)
        [old, "refs/heads/side", "saved", "refs/tags/saved", tag].each do |revision|
          result = BlameOracle.compare(root, repository, "f", revision, "before\n")
          result.revision.should eq(old)
          result[0].commit_oid.should eq(old)
        end
      end
    end

    it "blames #{format} files in bare repositories without an index or worktree" do
      BlameOracle.with_repo(format: format, bare: true) do |root, repository|
        initial = BlameOracle.commit(repository, "bare-initial", {"f" => "one\ntwo\n"})
        tip = BlameOracle.commit(repository, "bare-tip", {"f" => "one\nTWO\n"}, [initial])
        repository.refs.update("refs/heads/main", tip, expected_oid: nil)
        result = BlameOracle.compare(root, repository, "f", "HEAD", "one\nTWO\n")
        result.map(&.commit_oid).should eq([initial, tip])
        File.exists?(File.join(root, "index")).should be_false
      end
    end

    it "treats #{format} shallow commits as attribution boundaries without reading their parents" do
      BlameOracle.with_repo(format: format) do |root, repository|
        initial = BlameOracle.commit(repository, "shallow-initial", {"f" => "one\ntwo\n"})
        middle = BlameOracle.commit(repository, "shallow-middle", {"f" => "one\nTWO\n"}, [initial])
        tip = BlameOracle.commit(repository, "shallow-tip", {"f" => "one\nTWO\nthree\n"}, [middle])
        File.write(File.join(root, ".git", "shallow"), "#{middle}\n")
        File.delete(File.join(root, ".git", "objects", initial.byte_slice(0, 2), initial.byte_slice(2)))
        result = BlameOracle.compare(root, Git::Repository.new(root), "f", tip, "one\nTWO\nthree\n")
        result.map(&.commit_oid).should eq([middle, middle, tip])
        result.map(&.boundary?).should eq([true, true, false])
      end
    end

    it "preserves quoted and invalid-byte #{format} paths without a worktree file" do
      BlameOracle.with_repo(format: format) do |root, repository|
        path = "space tab\tquote\"slash\\raw\xff.txt"
        oid = BlameOracle.commit(repository, "path", {path => "bytes\0\xff\n"})
        result = BlameOracle.compare(root, repository, path, oid, "bytes\0\xff\n")
        result[0].original_path.to_slice.should eq(path.to_slice)
      end
    end

    it "rejects absent paths, directories, gitlinks and non-commit #{format} revisions" do
      BlameOracle.with_repo(format: format) do |root, repository|
        expect_raises(Git::Error) { repository.blame("f") }
        leaf = repository.write_blob("payload\n")
        child_tree = repository.write_tree([Git::Tree::Entry.new("child", "100644", leaf)])
        parent = BlameOracle.commit(repository, "parent", {"f" => "payload\n"})
        tree = repository.write_tree([
          Git::Tree::Entry.new("directory", "40000", child_tree),
          Git::Tree::Entry.new("gitlink", "160000", parent),
          Git::Tree::Entry.new("f", "100644", leaf),
        ])
        author = Git::Signature.new("Writer", "writer@example.invalid", 1_700_000_000_i64, 0)
        oid = repository.write_commit(tree: tree, author: author, committer: author, message: "kinds\n")
        ["missing", "directory", "gitlink"].each do |path|
          GitOracle.run(root, "blame", "--line-porcelain", oid, "--", path, check: false).success?.should be_false
          expect_raises(Git::Error) { repository.blame(path, oid) }
        end
        [leaf, tree, "refs/heads/missing", "0" * repository.object_format.hexsize].each do |revision|
          expect_raises(Git::Error) { repository.blame("f", revision) }
        end
        ["", "/f", "../f", "directory/../f", "./f", "f\0other"].each do |path|
          expect_raises(Git::Error) { repository.blame(path, oid) }
        end
      end
    end
  end
end
