require "spec"
require "../src/git"
require "./support/git_oracle"

describe "P17 native Git commit and annotated-tag writing" do
  ["sha1", "sha256"].each do |format|
    it "P17-O14 writes a #{format} commit that matches real git commit-tree" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        blob = repo.write_blob("payload\n")
        tree = repo.write_tree([Git::Tree::Entry.new("file", "100644", blob)])
        author = Git::Signature.new("Alice Example", "alice@example.invalid", 1_700_000_001_i64, 330)
        committer = Git::Signature.new("Bob Example", "bob@example.invalid", 1_700_000_022_i64, -420)
        message = "subject\n\nbody\n"
        oid = repo.write_commit(tree: tree, author: author, committer: committer, message: message)
        env = {
          "GIT_AUTHOR_NAME"     => author.name,
          "GIT_AUTHOR_EMAIL"    => author.email,
          "GIT_AUTHOR_DATE"     => "@#{author.unix_seconds} +0530",
          "GIT_COMMITTER_NAME"  => committer.name,
          "GIT_COMMITTER_EMAIL" => committer.email,
          "GIT_COMMITTER_DATE"  => "@#{committer.unix_seconds} -0700",
        }
        expected = GitOracle.run(root, "commit-tree", tree, "-F", "-", input: message, extra_env: env).stdout.strip
        oid.should eq(expected)
        stored = repo.read_object(oid, max_bytes: 1024)
        kind, raw = stored.type.to_s, stored.data
        kind.should eq("commit")
        GitOracle.assert_bytes!(raw, GitOracle.run(root, "cat-file", "commit", oid).stdout, "P17-O14")
        repo.read_commit(oid, max_bytes: 1024).subject.should eq("subject")
        repo.write_commit(tree: tree, author: author, committer: committer, message: message).should eq(oid)
        repo.head.oid.should be_nil
        GitOracle.run(root, "fsck", "--no-reflogs", "--unreachable")
      end
    end

    it "P17-O15 writes #{format} multi-parent commit and annotated tags" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        tree = repo.write_tree([] of Git::Tree::Entry)
        author = Git::Signature.new("A", "a@invalid.test", 1_700_000_010_i64, 0)
        parent1 = repo.write_commit(tree: tree, author: author, committer: author, message: "first\n")
        parent2 = repo.write_commit(tree: tree, author: author, committer: author, message: "second\n")
        body = "merge\n\nmessage\n"
        oid = repo.write_commit(tree: tree, parents: [parent1, parent2], author: author, committer: author, message: body)
        env = {
          "GIT_AUTHOR_NAME" => "A", "GIT_AUTHOR_EMAIL" => "a@invalid.test",
          "GIT_COMMITTER_NAME" => "A", "GIT_COMMITTER_EMAIL" => "a@invalid.test",
          "GIT_AUTHOR_DATE" => "@1700000010 +0000", "GIT_COMMITTER_DATE" => "@1700000010 +0000",
        }
        expected = GitOracle.run(root, "commit-tree", tree, "-p", parent1, "-p", parent2, "-F", "-",
          input: body, extra_env: env).stdout.strip
        oid.should eq(expected)
        repo.read_commit(oid, max_bytes: 1024).parents.should eq([parent1, parent2])
        tagger = Git::Signature.new("Tag Person", "tag@example.invalid", 1_700_000_099_i64, -90)
        message = "release\n\nannotation\n"
        tag_oid = repo.write_tag(object: oid, type: Git::ObjectType::Commit, name: "v1.2.3", tagger: tagger, message: message)
        env["GIT_COMMITTER_NAME"] = tagger.name
        env["GIT_COMMITTER_EMAIL"] = tagger.email
        env["GIT_COMMITTER_DATE"] = "@1700000099 -0130"
        GitOracle.run(root, "tag", "-a", "v1.2.3", oid, "-F", "-", input: message, extra_env: env)
        tag_oid.should eq(GitOracle.run(root, "rev-parse", "refs/tags/v1.2.3").stdout.strip)
        repo.read_object(tag_oid, max_bytes: 1024).should eq(Git::RawObject.new(Git::ObjectType::Tag, GitOracle.run(root, "cat-file", "tag", tag_oid).stdout))
        chained = repo.write_tag(object: tag_oid, type: Git::ObjectType::Tag, name: "nested", tagger: tagger, message: "nested\n")
        repo.read_object(chained, max_bytes: 1024).type.should eq(Git::ObjectType::Tag)
        GitOracle.run(root, "fsck", "--no-reflogs", "--unreachable")
      end
    end
  end

  it "P17-O16 encodes multi-line extension headers in canonical Git continuation syntax" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      signature = Git::Signature.new("Test", "test@example.invalid", 123_i64, 0)
      tree = repo.write_tree([] of Git::Tree::Entry)
      headers = [Git::Commit::Header.new("gpgsig", "-----BEGIN SIGNATURE-----\ndata\n-----END SIGNATURE-----"),
                 Git::Commit::Header.new("x-extension", "arbitrary")]
      raw = Git::Commit.encode(tree: tree, parents: [] of String, author: signature,
        committer: signature, message: "structured\n", extra_headers: headers)
      raw.should contain("gpgsig -----BEGIN SIGNATURE-----\n data\n -----END SIGNATURE-----\n")
      oid = repo.write_commit(tree: tree, author: signature, committer: signature,
        message: "structured\n", extra_headers: headers)
      oid.should eq(GitOracle.run(root, "hash-object", "-t", "commit", "--stdin", input: raw).stdout.strip)
      GitOracle.assert_bytes!(repo.read_object(oid, max_bytes: 4096).data, raw, "P17-O16")
    end
  end

  it "P17-O17 rejects malformed commit/tag metadata and budgets without writing" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      tree = repo.write_tree([] of Git::Tree::Entry)
      sig = Git::Signature.new("A", "a@b", 99_i64, 0)
      write = ->(signature : Git::Signature) do
        repo.write_commit(tree: tree, author: signature, committer: sig, message: "test")
      end
      expect_raises(Git::Error, /identity/) { write.call(Git::Signature.new("bad\nname", "a@b", 99_i64, 0)) }
      expect_raises(Git::Error, /offset/) { write.call(Git::Signature.new("ok", "a@b", 99_i64, 1500)) }
      expect_raises(Git::Error, /OID/) { repo.write_commit(tree: "a" * 64, author: sig, committer: sig, message: "x") }
      expect_raises(Git::Error, /OID/) { repo.write_commit(tree: tree, parents: ["bad"], author: sig, committer: sig, message: "x") }
      expect_raises(Git::Error, /budget/) { repo.write_commit(tree: tree, author: sig, committer: sig, message: "x", max_bytes: 10) }
      expect_raises(Git::Error, /budget/) { repo.write_commit(tree: tree, parents: [tree], author: sig, committer: sig, message: "x", max_parents: 0) }
      expect_raises(Git::Error, /header/) { repo.write_commit(tree: tree, author: sig, committer: sig, message: "x", extra_headers: [Git::Commit::Header.new("tree", "override")]) }
      expect_raises(Git::Error, /header/) { repo.write_commit(tree: tree, author: sig, committer: sig, message: "x", extra_headers: [Git::Commit::Header.new("gpgsig", "bad\rheader")]) }
      expect_raises(Git::Error, /budget/) { repo.write_commit(tree: tree, author: sig, committer: sig, message: "x", extra_headers: [Git::Commit::Header.new("encoding", "UTF-8")], max_headers: 0) }
      expect_raises(Git::Error, /tag name/) { repo.write_tag(object: tree, type: Git::ObjectType::Tree, name: "bad name", tagger: sig, message: "x") }
      expect_raises(Git::Error, /OID/) { repo.write_tag(object: "f" * 64, type: Git::ObjectType::Tree, name: "v1", message: "x") }
      expect_raises(Git::Error, /budget/) { repo.write_tag(object: tree, type: Git::ObjectType::Tree, name: "v1", message: "x", max_bytes: 10) }
      expect_raises(ArgumentError, /budget/) { repo.write_tag(object: tree, type: Git::ObjectType::Tree, name: "v1", message: "x", max_bytes: -1) }
    end
  end

  it "P17-O18 supports omitted taggers and explicitly missing low-level references" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      tag = repo.write_tag(object: "a" * 40, type: Git::ObjectType::Blob, name: "low-level", message: "raw tag", tagger: nil)
      expected = "object #{"a" * 40}\ntype blob\ntag low-level\n\nraw tag"
      tag.should eq(GitOracle.run(root, "hash-object", "--literally", "-t", "tag", "--stdin", input: expected).stdout.strip)
      repo.read_object(tag, max_bytes: 1024).should eq(Git::RawObject.new(Git::ObjectType::Tag, expected))
    end
  end

  it "P17-O19 cancels before commit/tag publication and preserves existing objects" do
    GitOracle.with_repo do |root|
      repo = Git::Repository.new(root)
      tree = repo.write_tree([] of Git::Tree::Entry)
      sig = Git::Signature.new("A", "a@b", 99_i64, 0)
      text = Git::Commit.encode(tree: tree, parents: [] of String, author: sig, committer: sig, message: "cancel")
      oid = Git::ObjectId.digest("commit", text)
      callback_count = 0
      expect_raises(Git::Error, /cancelled/) do
        repo.write_commit(tree: tree, author: sig, committer: sig, message: "cancel", check: -> do
          callback_count += 1
          raise Git::Error.new("cancelled") if callback_count == 3
        end)
      end
      callback_count.should eq(3)
      folder = File.join(root, ".git", "objects", oid[0, 2])
      Dir.children(folder).should be_empty
      tag_raw = Git::Tag.encode(object: tree, type: Git::ObjectType::Tree, name: "empty", message: "x", tagger: sig)
      tag_oid = Git::ObjectId.digest("tag", tag_raw)
      tag_checks = 0
      expect_raises(Git::Error, /cancelled/) do
        repo.write_tag(object: tree, type: Git::ObjectType::Tree, name: "empty", message: "x", tagger: sig,
          check: -> do
            tag_checks += 1
            raise Git::Error.new("cancelled") if tag_checks == 3
          end)
      end
      tag_checks.should eq(3)
      tag_fanout = File.join(root, ".git", "objects", tag_oid[0, 2])
      Dir.children(tag_fanout).should be_empty
      File.exists?(File.join(tag_fanout, tag_oid[2..])).should be_false
      repo.write_commit(tree: tree, author: sig, committer: sig, message: "cancel").should eq(oid)
      target = File.join(folder, oid[2..])
      inode = File.info(target)
      repo.write_commit(tree: tree, author: sig, committer: sig, message: "cancel").should eq(oid)
      File.info(target).same_file?(inode).should be_true
      # Loose objects are written read-only, as Git writes them.
      File.chmod(target, 0o644)
      File.write(target, "corrupt")
      expect_raises(Git::Error) { repo.write_commit(tree: tree, author: sig, committer: sig, message: "cancel") }
      File.read(target).should eq("corrupt")
    end
  end
end
