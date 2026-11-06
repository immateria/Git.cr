require "./git_oracle"

module MergePartialRecoverySpec
  OPERATIONS = {"merge", "cherry-pick", "revert", "rebase"}
  SIGNATURE  = Git::Signature.new("Recovery", "recovery@example.test", 1234567890_i64, 0)

  def self.write(root : String, path : String, data : String) : Nil
    absolute = File.join(root, path)
    Dir.mkdir_p(File.dirname(absolute))
    File.write(absolute, data)
  end

  def self.fixture(root : String, operation : String, file_ours : Bool) : {String, String}
    write(root, "node-sibling", "preserve tracked sibling\n")
    if operation == "revert"
      if file_ours
        write(root, "node/child", "base child\n")
      else
        write(root, "node", "base file\n")
      end
      GitOracle.run(root, "add", ".")
      GitOracle.run(root, "commit", "-qm", "base")
      GitOracle.run(root, "checkout", "-qb", "topic")
      if file_ours
        GitOracle.run(root, "rm", "node/child")
        write(root, "node", "source file\n")
      else
        GitOracle.run(root, "rm", "node")
        write(root, "node/child", "source child\n")
      end
      GitOracle.run(root, "add", "-A")
      GitOracle.run(root, "commit", "-qm", "topic")
      GitOracle.run(root, "checkout", "-qB", "main", "topic")
      write(root, file_ours ? "node" : "node/child", "changed\n")
    else
      write(root, "node", "base\n")
      GitOracle.run(root, "add", ".")
      GitOracle.run(root, "commit", "-qm", "base")
      GitOracle.run(root, "checkout", "-qb", "topic")
      if file_ours
        GitOracle.run(root, "rm", "node")
        write(root, "node/child", "child\n")
      else
        write(root, "node", "changed\n")
      end
      GitOracle.run(root, "add", "-A")
      GitOracle.run(root, "commit", "-qm", "topic")
      GitOracle.run(root, "checkout", "-q", "main")
      if file_ours
        write(root, "node", "changed\n")
      else
        GitOracle.run(root, "rm", "node")
        write(root, "node/child", "child\n")
      end
    end
    GitOracle.run(root, "add", "-A")
    GitOracle.run(root, "commit", "-qm", "main")
    GitOracle.run(root, "checkout", "-q", "topic") if operation == "rebase"
    write(root, "untracked-caller", "preserve untracked caller\n")
    {GitOracle.run(root, "rev-parse", "HEAD").stdout.strip,
     GitOracle.run(root, "ls-files", "-s").stdout}
  end

  def self.start(repo : Git::Repository, operation : String, check : Proc(Nil)? = nil) : Nil
    case operation
    when "merge"
      repo.merge("topic", author: SIGNATURE, committer: SIGNATURE, message: "merge", check: check)
    when "cherry-pick"
      repo.cherry_pick("topic", committer: SIGNATURE, check: check)
    when "revert"
      repo.revert("topic", author: SIGNATURE, committer: SIGNATURE, check: check)
    when "rebase"
      repo.rebase("main", committer: SIGNATURE, check: check)
    end
  end

  def self.abort(repo : Git::Repository, operation : String, check : Proc(Nil)? = nil) : Nil
    case operation
    when "merge"       then repo.merge.abort(check: check)
    when "cherry-pick" then repo.cherry_pick.abort(check: check)
    when "revert"      then repo.revert.abort(check: check)
    when "rebase"      then repo.rebase.abort(committer: SIGNATURE, check: check)
    end
  end

  def self.head_name(operation : String) : String
    case operation
    when "merge"       then "MERGE_HEAD"
    when "cherry-pick" then "CHERRY_PICK_HEAD"
    when "revert"      then "REVERT_HEAD"
    else                    "REBASE_HEAD"
    end
  end

  def self.expect_partial(operation : String, &block : ->) : Nil
    if operation == "merge"
      error = expect_raises(Git::Merge::PartialPublication) { yield }
      error.index_published.should be_false
      error.original_error.message.should eq("injected recovery failure")
    else
      error = expect_raises(Git::Sequencer::PartialPublication) { yield }
      error.index_published.should be_false
      error.original_error.message.should eq("injected recovery failure")
    end
  end

  def self.assert_restored(root : String, operation : String, original : {String, String}) : Nil
    GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(original[0])
    GitOracle.run(root, "ls-files", "-s").stdout.should eq(original[1])
    GitOracle.run(root, "status", "--porcelain").stdout.should eq("?? untracked-caller\n")
    File.read(File.join(root, "node-sibling")).should eq("preserve tracked sibling\n")
    File.read(File.join(root, "untracked-caller")).should eq("preserve untracked caller\n")
    Dir.children(root).select(&.starts_with?("node~")).should be_empty
    File.exists?(File.join(root, ".git", head_name(operation))).should be_false
    File.exists?(File.join(root, ".git", "CRYSTAL_MERGE_PATHS")).should be_false
    File.exists?(File.join(root, ".git", "CRYSTAL_SEQUENCER_PATHS")).should be_false
    File.exists?(File.join(root, ".git", "index.lock")).should be_false
    Git::Repository.new(root).rebase.state?.should be_nil if operation == "rebase"
  end
end
