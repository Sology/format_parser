# https://xiph.org/vorbis/doc/Vorbis_I_spec.pdf
# https://en.wikipedia.org/wiki/Ogg#Page_structure
class FormatParser::OggParser
  include FormatParser::IOUtils

  MAX_POSSIBLE_PAGE_SIZE = 65307
  OGG_MIME_TYPE = 'audio/ogg'

  def likely_match?(filename)
    filename =~ /\.ogg$/i
  end

  def call(io)
    # The format consists of chunks of data each called an "Ogg page". Each page
    # begins with the characters, "OggS", to identify the file as Ogg format.
    capture_pattern = safe_read(io, 4)
    return unless capture_pattern == 'OggS'

    io.seek(28) # skip not important bytes

    # Each header packet begins with the same header fields.
    #   1) packet_type: 8 bit value (the identification header is type 1)
    #   2) the characters v','o','r','b','i','s' as six octets
    packet_type, vorbis, _vorbis_version, channels, sample_rate = safe_read(io, 16).unpack('Ca6VCV')
    return unless packet_type == 1 && vorbis == 'vorbis'

    # In order to calculate the audio duration we have to read a
    # granule_position of the last Ogg page of the file. Unfortunately, we don't
    # know where the last page starts. But we do know that max size of an Ogg
    # page is 65307 bytes. So we read the last 65307 bytes from the file and try
    # to find the last page in this tail.
    pos = io.size - MAX_POSSIBLE_PAGE_SIZE
    pos = 0 if pos < 0
    io.seek(pos)
    tail = io.read(MAX_POSSIBLE_PAGE_SIZE)
    return unless tail

    granule_position = find_last_granule_position(tail)
    return unless granule_position

    duration = granule_position / sample_rate.to_f
    return if duration == Float::INFINITY

    FormatParser::Audio.new(
      format: :ogg,
      audio_sample_rate_hz: sample_rate,
      num_audio_channels: channels,
      media_duration_seconds: duration,
      content_type: OGG_MIME_TYPE,
    )
  end

  private

  def all_indices_of_substr_in_str(of_substring, in_string)
    last_i = 0
    found_at_indices = []
    while last_i = in_string.index(of_substring, last_i)
      found_at_indices << last_i
      last_i += of_substring.bytesize
    end
    found_at_indices
  end

  # Returns granule_position of the last valid Ogg page contained in the given
  # tail. Since the tail may contain multiple "OggS" entries the method searches
  # them recursively starting from the end. The search stops when the first
  # valid Oggs page is found.
  #
  # The granule position contains the offset of the page in terms of the
  # number of samples from the start of file. So once we know that number
  # we can estimate how long the file is. We _do_ need to add the number
  # of samples the granule covers though
  def find_last_granule_position(in_string)
    # The Ogg page always starts with "OggS". Find all of them
    # in the given tail, since we want to scan "tail to head" -
    # starting with the last index and going down to the first
    rev_indices = all_indices_of_substr_in_str('OggS', in_string).reverse
    rev_indices.each do |idx|
      if granule_pos = extract_granule_position_from_string_at(in_string, idx)
        return granule_pos
      end
    end
    nil # Nothing matched or the list of indices was empty
  end

  # Since the magic bits may occur inside the body of the page we have to
  # validate that what we found is actually an Ogg page by calculating the
  # checksum. For this reason we have to read the entire page and calculate
  # its checksum. In order to read the entire Ogg page we first have to read a
  # part of its header to find out the size of the page.
  def extract_granule_position_from_string_at(string, at)
    header_size = 27
    header_bytes = string.byteslice(at, header_size)
    return unless header_bytes && header_bytes.bytesize == header_size

    # Read the Ogg page header excluding the segment table (in other words read
    # first 27 bytes). See https://en.wikipedia.org/wiki/Ogg#Page_structure
    _capture_pattern,
    _version,
    _header_type,
    granule_position,
    _bitstream_serial_number,
    _page_sequence_number,
    checksum,
    num_bytes_page_segments = header_bytes.unpack('a4CCQ<VVVC')

    # Read the segment table part of the Ogg page header. Its size is stored in page_segments.
    #
    # The segment table is a vector of 8-bit values, each indicating the length
    # of the corresponding segment within the page body.
    # If there are no segments in the segment table the page is certainly invalid
    return if num_bytes_page_segments == 0

    # Read the segment table
    segment_table_pos = at + header_size
    segment_table = string.byteslice(segment_table_pos, num_bytes_page_segments)
    return unless segment_table && segment_table.bytesize == num_bytes_page_segments

    # Calculate the size of the Ogg page
    num_bytes_used_for_segments = segment_table.unpack('C*').inject(&:+)
    page_size = header_size + num_bytes_page_segments + num_bytes_used_for_segments

    # Read the entire page now that we know how much we have to read
    entire_page = string.byteslice(at, page_size)
    return unless entire_page && entire_page.bytesize == page_size

    # Compute and check the checksum. If this check fails it means one of the two:
    #   - the data is corrupted
    #   - the "OggS" capture pattern occures inside the body of the page and is
    #     we were scanning a random piece of content which was not an Ogg page
    return unless checksum == calculate_checksum(entire_page)

    # ...and only having gone through all these motions - return the granule position.
    granule_position
  end

  # Calculate the CRC using the 0x04C11DB7 polynomial. We cannot use Zlib since
  # it generates different checksums. Copied from https://github.com/anibali/ruby-ogg
  def calculate_checksum(data)
    crc_reg = 0
    data.each_byte.with_index do |byte, i|
      # The checksum is calculated over _the entire page_ but with the
      # placeholder for the checksum - the 4 bytes - zeroed out. The checksum
      # is then substituted _into_ the page at that offset. So when we go
      # over bytes at these offsets we will substitute them with 0s
      b = (22..25).cover?(i) ? 0 : byte
      crc_reg = (crc_reg << 8) ^ CRC_LOOKUP[((crc_reg >> 24) & 0xff) ^ b]
      crc_reg = crc_reg % 2**32
    end

    crc_reg
  end

  CRC_LOOKUP = [
    0x00000000, 0x04c11db7, 0x09823b6e, 0x0d4326d9,
    0x130476dc, 0x17c56b6b, 0x1a864db2, 0x1e475005,
    0x2608edb8, 0x22c9f00f, 0x2f8ad6d6, 0x2b4bcb61,
    0x350c9b64, 0x31cd86d3, 0x3c8ea00a, 0x384fbdbd,
    0x4c11db70, 0x48d0c6c7, 0x4593e01e, 0x4152fda9,
    0x5f15adac, 0x5bd4b01b, 0x569796c2, 0x52568b75,
    0x6a1936c8, 0x6ed82b7f, 0x639b0da6, 0x675a1011,
    0x791d4014, 0x7ddc5da3, 0x709f7b7a, 0x745e66cd,
    0x9823b6e0, 0x9ce2ab57, 0x91a18d8e, 0x95609039,
    0x8b27c03c, 0x8fe6dd8b, 0x82a5fb52, 0x8664e6e5,
    0xbe2b5b58, 0xbaea46ef, 0xb7a96036, 0xb3687d81,
    0xad2f2d84, 0xa9ee3033, 0xa4ad16ea, 0xa06c0b5d,
    0xd4326d90, 0xd0f37027, 0xddb056fe, 0xd9714b49,
    0xc7361b4c, 0xc3f706fb, 0xceb42022, 0xca753d95,
    0xf23a8028, 0xf6fb9d9f, 0xfbb8bb46, 0xff79a6f1,
    0xe13ef6f4, 0xe5ffeb43, 0xe8bccd9a, 0xec7dd02d,
    0x34867077, 0x30476dc0, 0x3d044b19, 0x39c556ae,
    0x278206ab, 0x23431b1c, 0x2e003dc5, 0x2ac12072,
    0x128e9dcf, 0x164f8078, 0x1b0ca6a1, 0x1fcdbb16,
    0x018aeb13, 0x054bf6a4, 0x0808d07d, 0x0cc9cdca,
    0x7897ab07, 0x7c56b6b0, 0x71159069, 0x75d48dde,
    0x6b93dddb, 0x6f52c06c, 0x6211e6b5, 0x66d0fb02,
    0x5e9f46bf, 0x5a5e5b08, 0x571d7dd1, 0x53dc6066,
    0x4d9b3063, 0x495a2dd4, 0x44190b0d, 0x40d816ba,
    0xaca5c697, 0xa864db20, 0xa527fdf9, 0xa1e6e04e,
    0xbfa1b04b, 0xbb60adfc, 0xb6238b25, 0xb2e29692,
    0x8aad2b2f, 0x8e6c3698, 0x832f1041, 0x87ee0df6,
    0x99a95df3, 0x9d684044, 0x902b669d, 0x94ea7b2a,
    0xe0b41de7, 0xe4750050, 0xe9362689, 0xedf73b3e,
    0xf3b06b3b, 0xf771768c, 0xfa325055, 0xfef34de2,
    0xc6bcf05f, 0xc27dede8, 0xcf3ecb31, 0xcbffd686,
    0xd5b88683, 0xd1799b34, 0xdc3abded, 0xd8fba05a,
    0x690ce0ee, 0x6dcdfd59, 0x608edb80, 0x644fc637,
    0x7a089632, 0x7ec98b85, 0x738aad5c, 0x774bb0eb,
    0x4f040d56, 0x4bc510e1, 0x46863638, 0x42472b8f,
    0x5c007b8a, 0x58c1663d, 0x558240e4, 0x51435d53,
    0x251d3b9e, 0x21dc2629, 0x2c9f00f0, 0x285e1d47,
    0x36194d42, 0x32d850f5, 0x3f9b762c, 0x3b5a6b9b,
    0x0315d626, 0x07d4cb91, 0x0a97ed48, 0x0e56f0ff,
    0x1011a0fa, 0x14d0bd4d, 0x19939b94, 0x1d528623,
    0xf12f560e, 0xf5ee4bb9, 0xf8ad6d60, 0xfc6c70d7,
    0xe22b20d2, 0xe6ea3d65, 0xeba91bbc, 0xef68060b,
    0xd727bbb6, 0xd3e6a601, 0xdea580d8, 0xda649d6f,
    0xc423cd6a, 0xc0e2d0dd, 0xcda1f604, 0xc960ebb3,
    0xbd3e8d7e, 0xb9ff90c9, 0xb4bcb610, 0xb07daba7,
    0xae3afba2, 0xaafbe615, 0xa7b8c0cc, 0xa379dd7b,
    0x9b3660c6, 0x9ff77d71, 0x92b45ba8, 0x9675461f,
    0x8832161a, 0x8cf30bad, 0x81b02d74, 0x857130c3,
    0x5d8a9099, 0x594b8d2e, 0x5408abf7, 0x50c9b640,
    0x4e8ee645, 0x4a4ffbf2, 0x470cdd2b, 0x43cdc09c,
    0x7b827d21, 0x7f436096, 0x7200464f, 0x76c15bf8,
    0x68860bfd, 0x6c47164a, 0x61043093, 0x65c52d24,
    0x119b4be9, 0x155a565e, 0x18197087, 0x1cd86d30,
    0x029f3d35, 0x065e2082, 0x0b1d065b, 0x0fdc1bec,
    0x3793a651, 0x3352bbe6, 0x3e119d3f, 0x3ad08088,
    0x2497d08d, 0x2056cd3a, 0x2d15ebe3, 0x29d4f654,
    0xc5a92679, 0xc1683bce, 0xcc2b1d17, 0xc8ea00a0,
    0xd6ad50a5, 0xd26c4d12, 0xdf2f6bcb, 0xdbee767c,
    0xe3a1cbc1, 0xe760d676, 0xea23f0af, 0xeee2ed18,
    0xf0a5bd1d, 0xf464a0aa, 0xf9278673, 0xfde69bc4,
    0x89b8fd09, 0x8d79e0be, 0x803ac667, 0x84fbdbd0,
    0x9abc8bd5, 0x9e7d9662, 0x933eb0bb, 0x97ffad0c,
    0xafb010b1, 0xab710d06, 0xa6322bdf, 0xa2f33668,
    0xbcb4666d, 0xb8757bda, 0xb5365d03, 0xb1f740b4
  ].freeze

  FormatParser.register_parser new, natures: :audio, formats: :ogg
end
