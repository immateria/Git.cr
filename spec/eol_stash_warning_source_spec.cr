require "./eol_stash_spec"

describe "stash warning callback attribute source snapshots" do
  ["sha1", "sha256"].each do |format|
    it "keeps #{format} untracked attributes and CRLF content consistent with a non-mutating callback" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "file.txt"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "config", "core.safecrlf", "warn")
        repo = Git::Repository.new(root)
        File.write(File.join(root, ".gitattributes"), EolStashFixture::CRLF)
        File.write(File.join(root, "file.txt"), "working\n")
        File.write(File.join(root, "new.txt"), "new\r\n")
        warnings = [] of String
        warning = ->(message : String) { warnings << message; nil }
        repo.stash.push(actor: EolStashFixture.actor, include_untracked: true, warning: warning).should_not be_nil
        warnings.size.should eq(1)
        repo.stash.apply(actor: EolStashFixture.actor).conflicts.should be_empty
        File.read(File.join(root, ".gitattributes")).should eq(EolStashFixture::CRLF)
        File.read(File.join(root, "new.txt")).should eq("new\r\n")
      end
    end

    it "rejects #{format} warning mutations of attributes captured after the warning was discovered" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "file.txt"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        GitOracle.run(root, "config", "core.safecrlf", "warn")
        repo = Git::Repository.new(root)
        attributes = File.join(root, ".gitattributes")
        File.write(attributes, EolStashFixture::CRLF)
        File.write(File.join(root, "file.txt"), "working\n")
        File.write(File.join(root, "new.txt"), "new\r\n")
        index = File.read(File.join(root, ".git", "index"))
        warning = ->(_message : String) { File.write(attributes, "*.txt -text\n"); nil }
        expect_raises(Git::Error, /worktree.*changed during save/) do
          repo.stash.push(actor: EolStashFixture.actor, include_untracked: true, warning: warning)
        end
        repo.refs.resolve?("refs/stash").should be_nil
        File.read(File.join(root, ".git", "index")).should eq(index)
        File.read(attributes).should eq("*.txt -text\n")
        File.read(File.join(root, "file.txt")).should eq("working\n")
        File.read(File.join(root, "new.txt")).should eq("new\r\n")
        File.exists?(File.join(root, ".git", "index.lock")).should be_false
      end
    end

    it "rejects #{format} changed attribute sources outside selected and captured paths" do
      ["untracked", "tracked", "info", "global"].each do |source|
        GitOracle.with_repo(format: format) do |root|
          File.write(File.join(root, "file.txt"), "base\n")
          File.write(File.join(root, "other.txt"), "base\n")
          attributes = case source
                       when "info"   then File.join(root, ".git", "info", "attributes")
                       when "global" then File.join(root, "external-attributes")
                       else               File.join(root, ".gitattributes")
                       end
          Dir.mkdir_p(File.dirname(attributes))
          if source == "tracked"
            File.write(attributes, EolStashFixture::CRLF)
          end
          GitOracle.run(root, "add", ".")
          GitOracle.run(root, "commit", "-qm", "base")
          GitOracle.run(root, "config", "core.safecrlf", "warn")
          if source == "global"
            GitOracle.run(root, "config", "core.attributesfile", attributes)
          end
          File.write(attributes, EolStashFixture::CRLF)
          File.write(File.join(root, "file.txt"), "working\n")
          File.write(File.join(root, "other.txt"), "other\r\n")
          repo = Git::Repository.new(root)
          index = File.read(File.join(root, ".git", "index"))
          warning = ->(_message : String) { File.write(attributes, "*.txt -text\n"); nil }
          expect_raises(Git::Error, /attribute source changed during save/) do
            repo.stash.push(actor: EolStashFixture.actor, paths: ["file.txt", "other.txt"], warning: warning)
          end
          repo.refs.resolve?("refs/stash").should be_nil
          File.read(File.join(root, ".git", "index")).should eq(index)
          File.read(attributes).should eq("*.txt -text\n")
          File.read(File.join(root, "file.txt")).should eq("working\n")
          File.read(File.join(root, "other.txt")).should eq("other\r\n")
          File.exists?(File.join(root, ".git", "index.lock")).should be_false
        end
      end
    end
  end
end
