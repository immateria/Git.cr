require "spec"
require "../src/git"
require "./support/git_oracle"

describe "Git object payload read budgets" do
  ["sha1", "sha256"].each do |format|
    ["loose", "packed"].each do |storage|
      it "accepts the maximum Int32 budget for a small #{storage} #{format} payload" do
        GitOracle.with_repo(format: format) do |root|
          repo = Git::Repository.new(root)
          payload = "a" * 200
          oid = Git::ObjectId.digest("blob", payload, repo.object_format)
          if storage == "loose"
            repo.write_blob(payload).should eq(oid)
          else
            pack = IO::Memory.new
            writer = Git::Pack::Writer.new(pack, repo.object_format, 1)
            writer.write_object(Git::ObjectType::Blob, payload.to_slice)
            writer.finish
            repo.index_pack(IO::Memory.new(pack.to_slice))
            repo = Git::Repository.new(root)
          end
          repo.read_object(oid, max_bytes: Int32::MAX).data.should eq(payload)
        end
      end
    end

    it "bounds loose #{format} payloads independently of envelope padding" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        payload = "a" * 200
        oid = repo.write_blob(payload)
        expect_raises(Git::Error, /budget|size limit/) { repo.read_object(oid, max_bytes: 128) }
        expect_raises(Git::Error, /budget|size limit/) { repo.read_object(oid, max_bytes: payload.bytesize - 1) }
        repo.read_object(oid, max_bytes: payload.bytesize).data.should eq(payload)
        empty = repo.write_blob("")
        repo.read_object(empty, max_bytes: 0).data.should eq("")
      end
    end

    it "applies the same #{format} payload budget to packed objects and cached delta bases" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        base = "a" * 200
        target = base + "b"
        base_oid = Git::ObjectId.digest("blob", base, repo.object_format)
        target_oid = Git::ObjectId.digest("blob", target, repo.object_format)
        empty_oid = Git::ObjectId.digest("blob", "", repo.object_format)
        pack = IO::Memory.new
        writer = Git::Pack::Writer.new(pack, repo.object_format, 3)
        offset, _ = writer.write_object(Git::ObjectType::Blob, base.to_slice)
        writer.write_ofs_delta(offset, Git::Pack::Delta.encode(base.to_slice, target.to_slice).not_nil!)
        writer.write_object(Git::ObjectType::Blob, Bytes.empty)
        writer.finish
        repo.index_pack(IO::Memory.new(pack.to_slice))
        repo = Git::Repository.new(root)
        expect_raises(Git::Error, /budget|size limit/) { repo.read_object(base_oid, max_bytes: base.bytesize - 1) }
        repo.read_object(base_oid, max_bytes: base.bytesize).data.should eq(base)
        repo.read_object(empty_oid, max_bytes: 0).data.should eq("")
        # Resolving a delta caches its base. That cache must not bypass a
        # smaller budget supplied by a later read of the base itself.
        repo.read_object(target_oid, max_bytes: target.bytesize).data.should eq(target)
        expect_raises(Git::Error, /budget|size limit/) { repo.read_object(base_oid, max_bytes: 128) }
        repo.read_object(base_oid, max_bytes: base.bytesize).data.should eq(base)
      end
    end
  end
end
