require 'spec_helper'
require 'webrick'

describe 'Fetching data from HTTP remotes' do
  before(:all) do
    log_file ||= StringIO.new
    log = WEBrick::Log.new(log_file)
    options = {
      Port: 9399,
      Logger: log,
      AccessLog: [
        [log, WEBrick::AccessLog::COMMON_LOG_FORMAT],
        [log, WEBrick::AccessLog::REFERER_LOG_FORMAT]
      ]
    }
    @server = WEBrick::HTTPServer.new(options)
    @server.mount '/', WEBrick::HTTPServlet::FileHandler, fixtures_dir
    @server.mount_proc '/redirect' do |req, res|
      res.status = 302
      res.header['Location'] = req.path.sub('/redirect', '')
    end
    trap('INT') { @server.stop }
    @server_thread = Thread.new { @server.start }
  end

  it '#parse_http is called without any option' do
    result = FormatParser.parse_http('http://localhost:9399/PNG/anim.png')

    expect(result.format).to eq(:png)
    expect(result.height_px).to eq(180)
  end

  it '#parse_http is called with hash options' do
    fake_result = double(nature: :audio, format: :aiff)
    expect_any_instance_of(FormatParser::AIFFParser).to receive(:call).and_return(fake_result)
    results = FormatParser.parse_http('http://localhost:9399/PNG/anim.png', results: :all)

    expect(results.count).to eq(2)
    expect(results).to include(fake_result)
  end

  it 'parses the animated PNG over HTTP' do
    file_information = FormatParser.parse_http('http://localhost:9399/PNG/anim.png')
    expect(file_information).not_to be_nil
    expect(file_information.nature).to eq(:image)
  end

  it 'parses the JPEGs exif data' do
    file_information = FormatParser.parse_http('http://localhost:9399/exif-orientation-testimages/jpg/top_left.jpg')
    expect(file_information).not_to be_nil
    expect(file_information.nature).to eq(:image)
    expect(file_information.format).to eq(:jpg)
    expect(file_information.orientation).to eq(:top_left)
  end

  it 'parses the TIFFs exif data' do
    file_information = FormatParser.parse_http('http://localhost:9399/TIFF/test.tif')
    expect(file_information).not_to be_nil
    expect(file_information.nature).to eq(:image)
    expect(file_information.format).to eq(:tif)
    expect(file_information.orientation).to eq(:top_left)
  end

  describe 'is able to correctly parse orientation for all remote JPEG EXIF examples from FastImage' do
    Dir.glob(fixtures_dir + '/exif-orientation-testimages/jpg/*.jpg').each do |jpeg_path|
      filename = File.basename(jpeg_path)
      it "is able to parse #{filename}" do
        remote_jpeg_path = jpeg_path.gsub(fixtures_dir, 'http://localhost:9399')
        file_information = FormatParser.parse_http(remote_jpeg_path)
        expect(file_information).not_to be_nil

        expect(file_information.orientation).to be_kind_of(Symbol)
        # Filenames in this dir correspond with the orientation of the file
        expect(filename.include?(file_information.orientation.to_s)).to be true
      end
    end
  end

  it 'correctly detects a PNG as a PNG without falling back to another filetype' do
    remote_png_url = 'http://localhost:9399/PNG/simulator_screenie.png'
    file_information = FormatParser.parse_http(remote_png_url)
    expect(file_information).not_to be_nil
    expect(file_information.format).to eq(:png)
  end

  describe 'when parsing remote fixtures' do
    Dir.glob(fixtures_dir + '/**/*.*').sort.each do |fixture_path|
      filename = File.basename(fixture_path)
      it "parses #{filename} without raising any errors" do
        remote_fixture_path = fixture_path.gsub(fixtures_dir, 'http://localhost:9399')
        # Some of the fixtures are in dirs with spaces
        cleaned_remote_fixture_path = remote_fixture_path.gsub(' ', '%20')
        FormatParser.parse_http(cleaned_remote_fixture_path)
      end
    end
  end

  context 'when the server responds with a redirect' do
    it 'follows the redirect' do
      file_information = FormatParser.parse_http('http://localhost:9399/redirect/TIFF/test.tif')
      expect(file_information.format).to eq(:tif)
    end
  end

  it 'sends provided HTTP headers in the request' do
    # Faraday is required only after calling .parse_http
    # This line is just to trigger this require, then it's possible to
    # add an expectation of how Faraday is initialized after.
    FormatParser.parse_http('invalid_url') rescue nil

    expect(Faraday)
      .to receive(:new)
      .with(headers: {'test-header' => 'test-value'})
      .and_call_original

    file_information = FormatParser.parse_http(
      'http://localhost:9399//TIFF/test.tif',
      headers: {'test-header' => 'test-value'}
    )

    expect(file_information.format).to eq(:tif)
  end

  after(:all) do
    @server.stop
    @server_thread.join(0.5)
  end
end
