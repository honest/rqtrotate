
module RQTRotate
  # Read a single atom and return an array of [size, type].
  def read_atom(datastream)
    datastream.read(8).unpack("NA4")
  end

  # return a list of top-level atoms and their absolute
  # positions
  def get_index(datastream)
    index = []

    while not datastream.eof?
      atom_size, atom_type = read_atom(datastream)
      index << [atom_type, datastream.pos - 8, atom_size]

      if atom_size < 8
        break
      else
        datastream.seek(atom_size - 8 , IO::SEEK_CUR)
      end
    end

    top_level_atoms = index.collect{|atom| atom[0]}
  
    ['ftyp', 'moov', 'mdat'].each do |atom_type|
      if not top_level_atoms.include?(atom_type)
        print "#{atom_type} atom not found, is this a valid MOV/MP4 file?"
        exit(1)
      end
    end

    index
  end

  # read through the stream and yield each atom to the
  # specified block
  def find_atoms(size, datastream, &block)
    stop = datastream.pos + size
    
    while datastream.pos < stop
      atom_size, atom_type = read_atom(datastream)

      exit(1) if atom_size == 0

      # 'trak's contiain child atoms
      if atom_type == 'trak'
        find_atoms(atom_size - 8, datastream) do |sub_atom_type|
          block.call sub_atom_type
        end
      elsif ['mvhd', 'tkhd'].include?(atom_type)
        block.call atom_type
      else
        datastream.seek(atom_size - 8, IO::SEEK_CUR)
      end
    end
  end

  # determine if an existing stream is rotated  
  def get_rotation(datastream)
    degrees = []

    process_stream(datastream) do |atom_type, matrix|
      9.times do |i|
        if (i + 1) % 3 == 0
          matrix[i] = matrix[i].to_f / (1 << 30)
        else
          matrix[i] = matrix[i].to_f / (1 << 16)
        end
      end

      if ['mvhd', 'tkhd'].include?(atom_type)
        deg = -(Math::asin(matrix[3]) * (180.0 / Math::PI)) % 360
        deg = (Math::acos(matrix[0]) * (180.0 / Math::PI)) if deg == 0
        degrees << deg if deg != 0
      end        
    end

    if degrees.count == 0
      0
    elsif degrees.count == 1
      degrees.pop
    else
      -1
    end
  end
  
  # take an existing stream and rotate it
  def rotate(datastream, rotation)
    process_stream(datastream) do |atom_type, matrix|
      if atom_type == 'tkhd'
        rad = rotation * Math::PI / 180.0
        cos_deg = ((1 << 16) * Math::cos(rad)).to_i
        sin_deg = ((1 << 16) * Math::sin(rad)).to_i

        #value = [cos_deg, sin_deg, 0, -sin_deg, cos_deg, 0, 0, 0, (1 << 30)].pack("O9")
        value = [cos_deg, sin_deg, 0, -sin_deg, cos_deg, 0, 0, 0, (1 << 30)].signed_bigendian_pack()
        
        datastream.seek(-36, 1)
        datastream.write(value)
      else
        9.times do |i|
          if (i + 1) % 3 == 0
            matrix[i] = matrix[i].to_f / (1 << 30)
          else
            matrix[i] = matrix[i].to_f / (1 << 16)
          end
        end        
      end
    end
  end

  def process_stream(datastream, &block)
    index = get_index(datastream)
    moov_size = -1

    index.each do |atom, pos, size| 
      if atom == 'moov'
        moov_size = size
        datastream.seek(pos + 8)
        break
      end
    end

    find_atoms(moov_size - 8, datastream) do |atom_type|
      vf = datastream.read(4)
      version = vf.unpack("C4")[0]
      flags = vf.unpack("N")[0] & 0x00ffffff

      if version == 1
        if atom_type == 'mvhd'
          datastream.read(28)
        elsif atom_type == 'tkhd'
          datastream.read(32)
        end
      elsif version == 0
        if atom_type == 'mvhd'
          datastream.read(16)
        elsif atom_type == 'tkhd'
          datastream.read(20)
        end
      end

      datastream.read(16)
      raw = datastream.read(36)
      # matrix = raw.unpack('O*') # pending patch acceptance to pack.c
      matrix = raw.signed_bigendian_unpack

      block.call atom_type, matrix
      
      if atom_type == 'mvhd'
        datastream.read(28)
      elsif atom_type == 'tkhd'
        datastream.read(8)
      end
    end # find_atoms
  end  # process_stream
end # module
