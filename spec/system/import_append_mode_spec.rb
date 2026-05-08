require 'spec_helper'

RSpec.describe 'POST /import mode=append', type: :request do
  let(:xlsx_path) { File.join(ROOT, 'Helix_Anchor_Dataset_CANDIDATE.xlsx') }

  it 'leaves existing rows in place and skips duplicates' do
    Seeder.run!(log: ->(_) {})
    customer_count = Customer.count
    usage_count    = UsageEvent.count

    post '/import',
      anchor_file: Rack::Test::UploadedFile.new(xlsx_path,
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', true),
      mode:        'append'

    expect(last_response.status).to eq(302)
    expect(Customer.count).to eq(customer_count)         # all customers already existed → no new rows
    expect(UsageEvent.count).to eq(usage_count)          # synthetic events already existed → guard kicks in
  end

  it 'replace mode (the default) still wipes and reseeds' do
    Seeder.run!(log: ->(_) {})
    Customer.first.update(name: 'Manually edited name')

    post '/import',
      anchor_file: Rack::Test::UploadedFile.new(xlsx_path,
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', true)
      # no mode param → defaults to 'replace'

    expect(last_response.status).to eq(302)
    expect(Customer.first.name).not_to eq('Manually edited name')   # row was wiped + reseeded
  end
end
