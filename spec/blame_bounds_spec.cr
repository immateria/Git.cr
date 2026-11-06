require "spec"
require "../src/git"
require "./support/blame_oracle"

describe "native Git blame bounds and read-only behavior" do
  ["sha1", "sha256"].each do |format|
    it "counts shared #{format} ancestors once at an exact history limit" do
      BlameOracle.with_repo(format: format) do |_root, repository|
        base = BlameOracle.commit(repository, "base", {"f" => "a\nb\n"})
        left = BlameOracle.commit(repository, "left", {"f" => "a\nL\n"}, [base])
        right = BlameOracle.commit(repository, "right", {"f" => "b\nR\n"}, [base])
        tip = BlameOracle.commit(repository, "tip", {"f" => "a\nb\n"}, [left, right])
        result = repository.blame("f", tip, max_history_nodes: 4)
        result.map(&.commit_oid).should eq([base, base])
        result.map(&.original_line).should eq([1, 2])
        result.scanned.should eq(4)
        expect_raises(Git::Error, /history.*budget/) do
          repository.blame("f", tip, max_history_nodes: 3)
        end
      end
    end

    it "bounds #{format} cached object payloads, lines and diff work" do
      BlameOracle.with_repo(format: format) do |_root, repository|
        first = BlameOracle.commit(repository, "first", {"f" => "first\nsecond\n"})
        tip = BlameOracle.commit(repository, "tip", {"f" => "first\nSECOND\n"}, [first])
        expect_raises(Git::Error, /total byte budget/) { repository.blame("f", tip, max_total_bytes: 0_i64) }
        expect_raises(Git::Error, /line budget/) { repository.blame("f", tip, max_lines: 1) }
        expect_raises(Git::Error, /work budget/) { repository.blame("f", tip, max_diff_work: 1_i64) }
        result = repository.blame("f", tip, max_lines: 4, max_diff_work: 100_000_i64)
        result.map(&.commit_oid).should eq([first, tip])
        objects = [first, tip, repository.read_commit(first).tree, repository.read_commit(tip).tree,
                   repository.rev_parse("#{first}:f"), repository.rev_parse("#{tip}:f")].uniq
        exact_bytes = objects.sum(0_i64) { |oid| repository.read_object(oid).data.bytesize.to_i64 }
        repository.blame("f", tip, max_total_bytes: exact_bytes).map(&.commit_oid).should eq([first, tip])
        expect_raises(Git::Error, /total byte budget/) do
          repository.blame("f", tip, max_total_bytes: exact_bytes - 1)
        end
        # Re-reading an identical blob does not consume the line budget twice.
        same = BlameOracle.commit(repository, "same", {"f" => "first\nsecond\n"}, [first])
        repository.blame("f", same, max_lines: 2).map(&.commit_oid).should eq([first, first])
        empty = BlameOracle.commit(repository, "empty", {"f" => ""})
        repository.blame("f", empty, max_lines: 0, max_diff_work: 0_i64).should be_empty
      end
    end

    it "counts only visited #{format} parents for first-parent and shallow blame" do
      BlameOracle.with_repo(format: format) do |root, repository|
        parents = (0...3).map do |index|
          BlameOracle.commit(repository, "parent#{index}", {"f" => "from parent #{index}\n"})
        end
        tip = BlameOracle.commit(repository, "octopus", {"f" => "from parent 0\n"}, parents)
        result = repository.blame("f", tip, first_parent: true, max_history_nodes: 2)
        result[0].commit_oid.should eq(parents[0])
        result.scanned.should eq(2)
        File.write(File.join(root, ".git", "shallow"), "#{tip}\n")
        shallow = Git::Repository.new(root).blame("f", tip, max_history_nodes: 1)
        shallow[0].commit_oid.should eq(tip)
        shallow[0].boundary?.should be_true
        shallow.scanned.should eq(1)
      end
    end

    it "enforces #{format} tree-entry and ancestor object budgets" do
      BlameOracle.with_repo(format: format) do |_root, repository|
        blob = repository.write_blob("kept\n")
        tree = repository.write_tree([
          Git::Tree::Entry.new("f", "100644", blob),
          Git::Tree::Entry.new("other", "100644", blob),
        ])
        sig = Git::Signature.new("Budget", "budget@example.test", 1_700_000_000_i64, 0)
        large = repository.write_commit(tree: tree, author: sig, committer: sig, message: "x" * 2000)
        tip = repository.write_commit(tree: tree, parents: [large], author: sig, committer: sig, message: "small")
        expect_raises(Git::Error, /entry budget/) { repository.blame("f", tip, max_entries: 1) }
        expect_raises(Git::Error, /budget|size limit/) { repository.blame("f", tip, max_object_bytes: 512) }
        repository.blame("f", tip, max_entries: 2, max_object_bytes: 4096)[0].commit_oid.should eq(large)
      end
    end

    it "ignores #{format} staged/working contents and preserves them on cancellation" do
      BlameOracle.with_repo(format: format) do |root, repository|
        oid = BlameOracle.commit(repository, "committed", {"f" => "committed\n"})
        repository.refs.update("refs/heads/main", oid, expected_oid: nil)
        repository.stage_blob("f", "staged\n")
        File.write(File.join(root, "f"), "working\n")
        File.write(File.join(root, "caller"), "untracked\n")
        index_path = File.join(root, ".git", "index")
        before_index = File.read(index_path)
        result = repository.blame("f")
        result[0].content.should eq("committed\n")
        result[0].commit_oid.should eq(oid)
        check = -> { raise Git::Error.new("caller cancelled blame") }
        expect_raises(Git::Error, /caller cancelled blame/) { repository.blame("f", check: check) }
        File.read(index_path).should eq(before_index)
        File.read(File.join(root, "f")).should eq("working\n")
        File.read(File.join(root, "caller")).should eq("untracked\n")
        repository.rev_parse("HEAD").should eq(oid)
        File.exists?(File.join(root, ".git", "index.lock")).should be_false
        File.exists?(File.join(root, ".git", "MERGE_HEAD")).should be_false
      end
    end

    it "keeps long #{format} author identities intact" do
      BlameOracle.with_repo(format: format) do |_root, repository|
        tree = repository.write_tree([Git::Tree::Entry.new("f", "100644", repository.write_blob("line\n"))])
        author = Git::Signature.new("Author " + "a" * 700, "author@example.test", 1_700_000_000_i64, 0)
        committer = Git::Signature.new("Committer " + "b" * 700, "committer@example.test", 1_700_000_099_i64, 0)
        oid = repository.write_commit(tree: tree, author: author, committer: committer, message: "long identities")
        line = repository.blame("f", oid)[0]
        line.author.should eq(author)
        line.committer.should eq(committer)
      end
    end
  end
end
