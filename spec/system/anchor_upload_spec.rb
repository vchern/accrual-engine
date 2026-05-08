require 'spec_helper'

RSpec.describe 'Anchor upload flow', type: :request do
  let(:xlsx_path) { File.join(ROOT, 'Helix_Anchor_Dataset_CANDIDATE.xlsx') }

  it 'GET /anchor renders the upload form on a clean DB' do
    get '/anchor'
    expect(last_response).to be_ok
    expect(last_response.body).to include('No reference data loaded')
    expect(last_response.body).to include('Upload &amp; seed')
  end

  it '/closes redirects to /anchor when no reference data is loaded' do
    get '/closes'
    expect(last_response.status).to eq(302)
    expect(last_response.headers['Location']).to end_with('/anchor')
  end

  it 'POST /anchor seeds the DB and redirects to /closes' do
    expect(Customer.count).to eq(0)

    file = Rack::Test::UploadedFile.new(xlsx_path,
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', true)
    post '/anchor', anchor_file: file

    expect(last_response.status).to eq(302)
    expect(last_response.headers['Location']).to end_with('/closes')

    expect(Customer.count).to       eq(3)
    expect(Sku.count).to            eq(3)
    expect(GlAccount.count).to      eq(4)
    expect(Vendor.count).to         eq(1)
    expect(GoodsReceipt.count).to   eq(1)
    expect(UsageEvent.count).to     be > 90  # 10 anchor + 90 synthetic
  end

  it 'GET /anchor shows loaded counts after upload' do
    file = Rack::Test::UploadedFile.new(xlsx_path,
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', true)
    post '/anchor', anchor_file: file

    get '/anchor'
    expect(last_response.body).to include('Reference data loaded')
    expect(last_response.body).to include('3 customers')
  end

  it 'rejects an upload missing the file param' do
    post '/anchor'
    expect(last_response.status).to eq(400)
  end

  it 'rejects a non-xlsx file' do
    require 'tempfile'
    f = Tempfile.new(['junk', '.txt'])
    f.write('not an xlsx')
    f.rewind
    file = Rack::Test::UploadedFile.new(f.path, 'text/plain')
    post '/anchor', anchor_file: file
    expect(last_response.status).to eq(400)
  ensure
    f&.close
    f&.unlink
  end
end
