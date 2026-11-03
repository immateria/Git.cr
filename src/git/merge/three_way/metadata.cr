module Git
  class Repository
    private def merge_metadata_exists? : Bool
      admin = DescriptorPath::Directory.open(@git_dir)
      begin
        {"MERGE_HEAD", "MERGE_MSG", "CRYSTAL_MERGE_ORIG"}.any? { |name| !!admin.stat?(name) }
      ensure
        admin.close
      end
    end

    private def merge_read_metadata?(admin : DescriptorPath::Directory, name : String) : String?
      io = admin.open_file?(name)
      return nil unless io
      begin
        raise Error.new("Git merge metadata not a regular file") unless io.info.type.file?
        raise Error.new("Git merge metadata budget exceeded") if io.info.size > 65_536
        contents = IO::Memory.new
        IO.copy(io, contents, 65_537_i64)
        raise Error.new("Git merge metadata budget exceeded") if contents.size > 65_536
        contents.to_s
      ensure
        io.close unless io.closed?
      end
    end

    private def merge_write_metadata!(admin : DescriptorPath::Directory,
                                      branch : String, ours : String, theirs : String,
                                      message : String) : Nil
      # Publish MERGE_HEAD last: its presence implies that original state
      # and the message already exist and are fsynced. Failure in either
      # earlier file creates no apparently valid in-progress merge.
      contents = {"CRYSTAL_MERGE_ORIG" => "#{branch}\n#{ours}\n",
                  "MERGE_MSG" => message, "MERGE_HEAD" => "#{theirs}\n"}
      contents.each do |name, value|
        io = admin.open_file(name, LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o600)
        begin
          io.write(value.to_slice)
          io.flush
          io.fsync
        ensure
          io.close unless io.closed?
        end
        admin.sync
      end
    end

    private def merge_clear_metadata!(admin : DescriptorPath::Directory,
                                      branch : String, ours : String, theirs : String) : Nil
      raise Error.new("Git merge admin directory redirected") unless admin.attached_at?(@git_dir)
      raise Error.new("Git merge HEAD state changed") unless merge_state? == {branch, ours, theirs}
      {"MERGE_HEAD", "MERGE_MSG", "CRYSTAL_MERGE_ORIG"}.each do |name|
        raise Error.new("Git merge metadata missing during cleanup") unless admin.stat?(name)
        admin.unlink(name)
        admin.sync
      end
    end
  end
end
