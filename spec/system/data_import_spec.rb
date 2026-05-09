require 'spec_helper'

RSpec.describe 'Data import flow', type: :request do
  let(:xlsx_path) { File.join(ROOT, 'Helix_Anchor_Dataset_CANDIDATE.xlsx') }

  it 'GET /import renders the upload form on a clean DB' do
    get '/import'
    expect(last_response).to be_ok
    expect(last_response.body).to include('No reference data loaded')
    expect(last_response.body).to include('Data import')
  end

  it '/closes redirects to /import when no reference data is loaded' do
    get '/closes'
    expect(last_response.status).to eq(302)
    expect(last_response.headers['Location']).to end_with('/import')
  end

  it 'POST /import seeds the DB and redirects to /closes' do
    expect(Customer.count).to eq(0)

    file = Rack::Test::UploadedFile.new(xlsx_path,
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', true)
    post '/import', anchor_file: file

    expect(last_response.status).to eq(302)
    expect(last_response.headers['Location']).to end_with('/closes')

    expect(Customer.count).to       eq(3)
    expect(Sku.count).to            eq(3)
    expect(GlAccount.count).to      eq(4)
    expect(Vendor.count).to         eq(1)
    expect(GoodsReceipt.count).to   eq(1)
    expect(UsageEvent.count).to     be > 90  # 10 anchor + 90 synthetic
  end

  it 'GET /import shows loaded counts after upload' do
    file = Rack::Test::UploadedFile.new(xlsx_path,
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', true)
    post '/import', anchor_file: file

    get '/import'
    expect(last_response.body).to include('Reference data loaded')
    expect(last_response.body).to include('3 customers')
  end

  it 'rejects an upload missing the file param' do
    post '/import'
    expect(last_response.status).to eq(400)
  end

  it 'rejects a non-xlsx file' do
    require 'tempfile'
    f = Tempfile.new(['junk', '.txt'])
    f.write('not an xlsx')
    f.rewind
    file = Rack::Test::UploadedFile.new(f.path, 'text/plain')
    post '/import', anchor_file: file
    expect(last_response.status).to eq(400)
  ensure
    f&.close
    f&.unlink
  end

  it 'POST /import/sample loads the bundled XLSX' do
    expect(File.exist?(File.join(ROOT, 'Helix_Anchor_Dataset_CANDIDATE.xlsx'))).to be true
    expect(Customer.count).to eq(0)

    post '/import/sample'
    expect(last_response.status).to eq(302)
    expect(last_response.headers['Location']).to end_with('/closes')
    expect(Customer.count).to eq(3)
    expect(GoodsReceipt.count).to eq(1)
  end

  it 'GET /import shows both bundled-sample buttons when files are present' do
    get '/import'
    expect(last_response.body).to include('Load canonical')
    expect(last_response.body).to include('/import/sample')
    expect(last_response.body).to include('Load expanded demo')
    expect(last_response.body).to include('/import/demo')
  end

  it 'POST /import/demo loads the expanded demo dataset' do
    expect(File.exist?(File.join(ROOT, 'Helix_Demo_Expanded.xlsx'))).to be true
    expect(Customer.count).to eq(0)

    post '/import/demo'
    expect(last_response.status).to eq(302)
    expect(last_response.headers['Location']).to end_with('/closes')
    expect(Customer.count).to eq(5)         # 3 anchor + 2 new (Tokyo, London)
    expect(Sku.count).to eq(5)              # 3 anchor + GPU-A100-HR + BANDWIDTH-TB
    expect(GoodsReceipt.count).to eq(2)
  end
end
