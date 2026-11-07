require "git"
require "file_utils"

module WorkflowConsumer
  ACTOR = Git::Signature.new("Native consumer", "consumer@example.invalid", 1_700_000_000_i64, 0)

  def self.expect(condition : Bool, message : String) : Nil
    raise message unless condition
  end

  def self.write_text(root : String, path : String, canonical : String) : Nil
    expect(!canonical.includes?('\r'), "consumer input must be canonical text")
    File.write(File.join(root, path), canonical.gsub("\n", "\r\n"))
  end

  def self.lines(first : String, last : String) : String
    "#{first}\nanchor one\nanchor two\nanchor three\nanchor four\nanchor five\nanchor six\n#{last}\n"
  end

  def self.commit(repository : Git::Repository, message : String) : String
    repository.stage
    repository.commit(author: ACTOR, committer: ACTOR, message: message + "\n")
  end

  def self.with_repository(format : Git::ObjectId::Format, label : String,
                           &block : Git::Repository, String, Git::Config -> Nil) : Nil
    fixtures = File.join(__DIR__, "repos")
    Dir.mkdir_p(fixtures)
    root = File.tempname("#{label}-#{format}", dir: fixtures)
    Dir.mkdir_p(root)
    begin
      repository = Git::Repository.init(root, object_format: format)
      File.open(File.join(root, ".git", "config"), "a") do |file|
        file << "\n[core]\n autocrlf = true\n"
      end
      File.write(File.join(root, ".gitattributes"), "*.txt text eol=crlf\n")
      config = repository.config(command_values: [{"core.safecrlf", "false"}])
      expect(File.directory?(File.join(root, ".git")), "fixture metadata must be an ordinary directory")
      block.call(repository, root, config)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  def self.expect_state(repository : Git::Repository, root : String, path : String,
                        worktree_text : String, index_text : String, label : String) : Nil
    expect(File.read(File.join(root, path)) == worktree_text.gsub("\n", "\r\n"), "#{label}: raw worktree bytes")
    entry = repository.index_entries.find { |item| item.path == path && item.stage == 0 }
    expect(!entry.nil?, "#{label}: missing stage-zero index entry")
    indexed = entry.not_nil!
    expected_oid = Git::ObjectId.digest("blob", index_text, repository.object_format)
    expect(indexed.oid == expected_oid, "#{label}: noncanonical index ID")
    expect(repository.read_object(indexed.oid).data == index_text, "#{label}: noncanonical index blob")
  end

  def self.expect_clean(repository : Git::Repository, label : String) : Nil
    expect(repository.working_changes.empty?, "#{label}: unexpected worktree changes")
    expect(repository.diff.empty?, "#{label}: unexpected worktree diff")
    expect(repository.diff(cached: true).empty?, "#{label}: unexpected staged diff")
  end

  def self.expect_commit_file(repository : Git::Repository, revision : String,
                              path : String, canonical : String, label : String) : Nil
    oid = repository.rev_parse("#{revision}:#{path}")
    expect(repository.read_object(oid).data == canonical, "#{label}: noncanonical saved blob")
  end

  def self.merge_and_fast_forward(format : Git::ObjectId::Format) : Nil
    with_repository(format, "merge") do |repository, root, config|
      base_text = lines("base top", "base bottom")
      write_text(root, "file.txt", base_text)
      commit(repository, "merge base")
      repository.switch("fast", create: true)
      fast_text = lines("fast top", "base bottom")
      write_text(root, "file.txt", fast_text)
      fast_oid = commit(repository, "fast target")
      repository.switch("main")
      fast = repository.fast_forward("fast", actor: ACTOR, config: config)
      expect(fast.target_oid == fast_oid, "fast-forward: wrong target")
      expect(repository.rev_parse("HEAD") == fast_oid, "fast-forward: HEAD did not advance")
      expect_state(repository, root, "file.txt", fast_text, fast_text, "fast-forward")
      expect_clean(repository, "fast-forward")

      repository.switch("topic", create: true)
      write_text(root, "file.txt", lines("topic top", "base bottom"))
      topic_oid = commit(repository, "topic change")
      repository.switch("main")
      write_text(root, "file.txt", lines("fast top", "main bottom"))
      main_oid = commit(repository, "main change")
      merged = repository.merge("topic", author: ACTOR, committer: ACTOR,
        message: "native merge\n", config: config)
      expect(merged.conflicts.empty?, "merge: unexpected conflict")
      merged_oid = merged.commit_oid.not_nil!
      expect(repository.read_commit(merged_oid).parents == [main_oid, topic_oid], "merge: wrong parents")
      expected = lines("topic top", "main bottom")
      expect_state(repository, root, "file.txt", expected, expected, "merge")
      expect_commit_file(repository, "HEAD", "file.txt", expected, "merge")
      expect_clean(repository, "merge")
      puts "#{format}: native fast-forward and three-way merge passed"
    end
  end

  def self.cherry_pick_and_revert(format : Git::ObjectId::Format) : Nil
    with_repository(format, "replay") do |repository, root, config|
      write_text(root, "file.txt", lines("base top", "base bottom"))
      commit(repository, "replay base")
      repository.switch("topic", create: true)
      write_text(root, "file.txt", lines("picked top", "base bottom"))
      source = commit(repository, "pick this")
      repository.switch("main")
      main_text = lines("base top", "main bottom")
      write_text(root, "file.txt", main_text)
      commit(repository, "independent main change")
      picked = repository.cherry_pick(source, committer: ACTOR, config: config)
      expect(picked.conflicts.empty?, "cherry-pick: unexpected conflict")
      picked_oid = picked.commit_oid.not_nil!
      picked_text = lines("picked top", "main bottom")
      expect_state(repository, root, "file.txt", picked_text, picked_text, "cherry-pick")
      expect_commit_file(repository, "HEAD", "file.txt", picked_text, "cherry-pick")
      expect_clean(repository, "cherry-pick")

      reverted = repository.revert(picked_oid, author: ACTOR, committer: ACTOR, config: config)
      expect(reverted.conflicts.empty? && !reverted.commit_oid.nil?, "revert: unexpected stop")
      expect_state(repository, root, "file.txt", main_text, main_text, "revert")
      expect_commit_file(repository, "HEAD", "file.txt", main_text, "revert")
      expect_clean(repository, "revert")
      puts "#{format}: native cherry-pick and revert passed"
    end
  end

  def self.rebase_onto(format : Git::ObjectId::Format) : Nil
    with_repository(format, "rebase") do |repository, root, config|
      write_text(root, "file.txt", lines("base top", "base bottom"))
      base = commit(repository, "rebase base")
      repository.switch("topic", create: true)
      write_text(root, "file.txt", lines("topic top", "base bottom"))
      commit(repository, "topic first")
      write_text(root, "extra.txt", "topic extra\n")
      commit(repository, "topic second")
      repository.switch("main")
      write_text(root, "file.txt", lines("base top", "onto bottom"))
      onto = commit(repository, "onto change")
      repository.switch("topic")

      result = repository.rebase(base, onto: "main", committer: ACTOR, config: config)
      expect(result.completed && result.conflicts.empty?, "rebase: unexpected stop")
      expect(result.total == 2 && result.next_index == 2, "rebase: wrong replay count")
      expect(repository.rev_parse("HEAD") == result.current_head, "rebase: wrong HEAD")
      first_replayed = repository.read_commit(result.current_head).parents.first
      expect(repository.read_commit(first_replayed).parents == [onto], "rebase: wrong onto parent")
      expected = lines("topic top", "onto bottom")
      expect_state(repository, root, "file.txt", expected, expected, "rebase")
      expect_state(repository, root, "extra.txt", "topic extra\n", "topic extra\n", "rebase extra")
      expect_commit_file(repository, "HEAD", "file.txt", expected, "rebase")
      expect(repository.rebase.state?.nil? && repository.sequencer.state?.nil?, "rebase: metadata remains")
      expect_clean(repository, "rebase")
      puts "#{format}: native two-commit rebase onto a disjoint edit passed"
    end
  end

  def self.stash_push_apply_pop(format : Git::ObjectId::Format) : Nil
    with_repository(format, "stash") do |repository, root, config|
      write_text(root, "file.txt", "base\n")
      commit(repository, "stash base")
      write_text(root, "file.txt", "staged\n")
      repository.stage_file("file.txt", config: config)
      write_text(root, "file.txt", "unstaged\n")
      write_text(root, "untracked.txt", "untracked\n")
      warnings = [] of String
      warning = ->(message : String) { warnings << message; nil }
      saved = repository.stash.push(actor: ACTOR, message: "native stash",
        include_untracked: true, config: config, warning: warning).not_nil!
      expect(warnings.empty?, "stash push: unexpected safecrlf warning")
      expect_commit_file(repository, saved.oid, "file.txt", "unstaged\n", "stash worktree")
      expect_commit_file(repository, saved.index_oid, "file.txt", "staged\n", "stash index")
      expect_commit_file(repository, saved.untracked_oid.not_nil!, "untracked.txt", "untracked\n", "stash untracked")
      expect_state(repository, root, "file.txt", "base\n", "base\n", "stash cleanup")
      expect(!File.exists?(File.join(root, "untracked.txt")), "stash push: untracked file was not removed")
      expect_clean(repository, "stash cleanup")

      applied = repository.stash.apply(actor: ACTOR, restore_index: true, config: config)
      expect(applied.conflicts.empty? && applied.index_restored, "stash apply: unexpected result")
      expect_state(repository, root, "file.txt", "unstaged\n", "staged\n", "stash apply")
      expect(File.read(File.join(root, "untracked.txt")) == "untracked\r\n", "stash apply: raw untracked bytes")
      expect(repository.stash.list.map(&.oid) == [saved.oid], "stash apply: saved entry changed")

      repository.reset(mode: Git::Reset::Mode::Hard, actor: ACTOR, config: config)
      File.delete(File.join(root, "untracked.txt"))
      expect_state(repository, root, "file.txt", "base\n", "base\n", "stash pop predecessor")
      popped = repository.stash.pop(actor: ACTOR, restore_index: true, config: config)
      expect(popped.dropped && popped.applied.conflicts.empty?, "stash pop: entry was not cleanly dropped")
      expect_state(repository, root, "file.txt", "unstaged\n", "staged\n", "stash pop")
      expect(File.read(File.join(root, "untracked.txt")) == "untracked\r\n", "stash pop: raw untracked bytes")
      expect(repository.stash.list.empty?, "stash pop: saved entry remains")
      puts "#{format}: native stash push, apply and pop passed"
    end
  end
end

{Git::ObjectId::Format::SHA1, Git::ObjectId::Format::SHA256}.each do |format|
  WorkflowConsumer.merge_and_fast_forward(format)
  WorkflowConsumer.cherry_pick_and_revert(format)
  WorkflowConsumer.rebase_onto(format)
  WorkflowConsumer.stash_push_apply_pop(format)
end
