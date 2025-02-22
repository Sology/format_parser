require 'spec_helper'

describe FormatParser::RemoteIO do
  it_behaves_like 'an IO object compatible with IOConstraint'

  it 'returns the partial content when the server supplies a 206 status' do
    rio = described_class.new('https://images.invalid/img.jpg')

    fake_resp = double(headers: {'Content-Range' => '10-109/2577'}, status: 206, body: 'This is the response')
    faraday_conn = instance_double(Faraday::Connection, get: fake_resp)
    allow(Faraday).to receive(:new).and_return(faraday_conn)
    expect(faraday_conn).to receive(:get).with('https://images.invalid/img.jpg', nil, range: 'bytes=10-109')

    rio.seek(10)
    read_result = rio.read(100)
    expect(read_result).to eq('This is the response')
  end

  it 'returns the entire content when the server supplies the Content-Range response but sends a 200 status' do
    rio = described_class.new('https://images.invalid/img.jpg')

    fake_resp = double(headers: {'Content-Range' => '10-109/2577'}, status: 200, body: 'This is the response')
    faraday_conn = instance_double(Faraday::Connection, get: fake_resp)
    allow(Faraday).to receive(:new).and_return(faraday_conn)
    expect(faraday_conn).to receive(:get).with('https://images.invalid/img.jpg', nil, range: 'bytes=10-109')

    rio.seek(10)
    read_result = rio.read(100)
    expect(read_result).to eq('This is the response')
  end

  it 'raises a specific error for all 4xx responses except 416' do
    rio = described_class.new('https://images.invalid/img.jpg')

    fake_resp = double(headers: {}, status: 403, body: 'Please log in')
    faraday_conn = instance_double(Faraday::Connection, get: fake_resp)
    allow(Faraday).to receive(:new).and_return(faraday_conn)
    expect(faraday_conn).to receive(:get).with('https://images.invalid/img.jpg', nil, range: 'bytes=100-199')

    rio.seek(100)
    expect { rio.read(100) }.to raise_error(/replied with a 403 and refused/)
  end

  it 'returns nil on a 416 response' do
    rio = described_class.new('https://images.invalid/img.jpg')

    fake_resp = double(headers: {}, status: 416, body: 'You stepped off the ledge of the range')
    faraday_conn = instance_double(Faraday::Connection, get: fake_resp)
    allow(Faraday).to receive(:new).and_return(faraday_conn)
    expect(faraday_conn).to receive(:get).with('https://images.invalid/img.jpg', nil, range: 'bytes=100-199')

    rio.seek(100)
    expect(rio.read(100)).to be_nil
  end

  it 'sets the status_code of the exception on a 4xx response from upstream' do
    rio = described_class.new('https://images.invalid/img.jpg')

    fake_resp = double(headers: {}, status: 403, body: 'Please log in')
    faraday_conn = instance_double(Faraday::Connection, get: fake_resp)
    allow(Faraday).to receive(:new).and_return(faraday_conn)
    expect(faraday_conn).to receive(:get).with('https://images.invalid/img.jpg', nil, range: 'bytes=100-199')

    rio.seek(100)
    # rubocop: disable Lint/AmbiguousBlockAssociation
    expect { rio.read(100) }.to raise_error { |e| expect(e.status_code).to eq(403) }
  end

  it 'returns a nil when the range cannot be satisfied and the response is 416' do
    rio = described_class.new('https://images.invalid/img.jpg')

    fake_resp = double(headers: {}, status: 416, body: 'You jumped off the end of the file maam')
    faraday_conn = instance_double(Faraday::Connection, get: fake_resp)
    allow(Faraday).to receive(:new).and_return(faraday_conn)
    expect(faraday_conn).to receive(:get).with('https://images.invalid/img.jpg', nil, range: 'bytes=100-199')

    rio.seek(100)
    expect(rio.read(100)).to be_nil
  end

  it 'does not overwrite size when the range cannot be satisfied and the response is 416' do
    rio = described_class.new('https://images.invalid/img.jpg')

    fake_resp1 = double(headers: {'Content-Range' => 'bytes 0-0/13'}, status: 206, body: 'a')
    fake_resp2 = double(headers: {}, status: 416, body: 'You jumped off the end of the file maam')

    faraday_conn = instance_double(Faraday::Connection)
    allow(Faraday).to receive(:new).and_return(faraday_conn)
    expect(faraday_conn).to receive(:get)
      .with('https://images.invalid/img.jpg', nil, range: 'bytes=0-0')
      .ordered
      .and_return(fake_resp1)
    expect(faraday_conn).to receive(:get)
      .with('https://images.invalid/img.jpg', nil, range: 'bytes=100-199')
      .ordered
      .and_return(fake_resp2)

    rio.read(1)

    expect(rio.size).to eq(13)

    rio.seek(100)
    expect(rio.read(100)).to be_nil

    expect(rio.size).to eq(13)
  end

  it 'raises a specific error for all 5xx responses' do
    rio = described_class.new('https://images.invalid/img.jpg')

    fake_resp = double(headers: {}, status: 502, body: 'Guru meditation')
    faraday_conn = instance_double(Faraday::Connection, get: fake_resp)
    allow(Faraday).to receive(:new).and_return(faraday_conn)
    expect(faraday_conn).to receive(:get).with('https://images.invalid/img.jpg', nil, range: 'bytes=100-199')

    rio.seek(100)
    expect { rio.read(100) }.to raise_error(/replied with a 502 and we might want to retry/)
  end

  it 'maintains and exposes #pos' do
    rio = described_class.new('https://images.invalid/img.jpg')

    expect(rio.pos).to eq(0)

    fake_resp = double(headers: {'Content-Range' => 'bytes 0-0/13'}, status: 206, body: 'a')
    faraday_conn = instance_double(Faraday::Connection, get: fake_resp)
    allow(Faraday).to receive(:new).and_return(faraday_conn)
    expect(faraday_conn).to receive(:get).with('https://images.invalid/img.jpg', nil, range: 'bytes=0-0')
    rio.read(1)

    expect(rio.pos).to eq(1)
  end
end
