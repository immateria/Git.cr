module Git
  # The four kinds of Git object. to_s gives Git's spelling ("commit").
  enum ObjectType
    Commit = 1
    Tree   = 2
    Blob   = 3
    Tag    = 4

    def to_s(io : IO) : Nil
      io << to_s
    end

    def to_s : String
      case self
      in .commit? then "commit"
      in .tree?   then "tree"
      in .blob?   then "blob"
      in .tag?    then "tag"
      end
    end
  end

  # A stored object: its type and its contents without the header.
  record RawObject, type : ObjectType, data : String

  # A stored object's type and size, read without inflating its contents.
  record ObjectHeader, type : ObjectType, size : Int64
end
