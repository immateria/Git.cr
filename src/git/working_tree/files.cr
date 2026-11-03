module Git
  class WorkingTree
    # One owner for verifying on-disk working-file ancestors. Never follow a
    # symlinked parent, including when inspecting an indexed symlink itself.
    # Missing parents are allowed: a missing tracked file is a deletion.
    private def verify_working_parents!(relative : String, &check : -> Nil) : Nil
      PathBytes.validate_relative!(relative, max_depth: Metadata::MAX_DEPTH)
      parent = @root
      relative.split('/')[0...-1].each do |part|
        check.call
        parent = File.join(parent, part)
        raise Error.new("Git working directory is a symlink") if File.symlink?(parent)
        if File.exists?(parent)
          raise Error.new("Git working directory redirected") unless Dir.exists?(parent) && File.realpath(parent) == parent
        end
      end
    end

    # Shared bounded, identity-checked regular-file read for worktree status
    # and per-file diffs. The caller is responsible for path authorization.
    private def read_working_regular(relative : String, max_bytes : Int32, &check : -> Nil) : {String, String, String}
      verify_working_parents!(relative) { check.call }
      absolute = File.join(@root, relative)
      raise Error.new("Git working file is a symlink or not regular") if File.symlink?(absolute) || !File.file?(absolute) || File.realpath(absolute) != absolute
      before = File.info(absolute, follow_symlinks: false)
      raise Error.new("Git working file exceeds byte budget") if before.size > max_bytes || before.size > @max_scan_bytes
      buffer = IO::Memory.new
      File.open(absolute) do |file|
        opened = file.info
        raise Error.new("Git working file changed before read") unless opened.same_file?(before)
        IO.copy(file, buffer, max_bytes.to_i64 + 1)
      end
      check.call
      verify_working_parents!(relative) { check.call }
      after = File.info(absolute, follow_symlinks: false)
      raise Error.new("Git working file changed during read") unless after.same_file?(before) &&
                                                                     after.size == before.size &&
                                                                     after.modification_time == before.modification_time &&
                                                                     after.permissions == before.permissions &&
                                                                     buffer.size == before.size && !File.symlink?(absolute)
      text = buffer.to_s
      {ObjectId.digest("blob", text, @object_format), after.permissions.value & 0o111 != 0 ? "100755" : "100644", text}
    end
  end
end
