require 'spec_helper'

RSpec.describe 'POST /import schema validation', type: :request do
  it 'returns 422 with errors and does NOT wipe the DB on validation failure' do
    Seeder.run!(log: ->(_) {})
    pre_count = Customer.count
    expect(pre_count).to be > 0

    allow(Seeder).to receive(:validate!)
      .and_raise(Seeder::SchemaError.new(["Sheet 'customers', column 3: expected 'currency', got 'CURRENCY'"]))

    file = Rack::Test::UploadedFile.new(
      File.join(ROOT, 'Helix_Anchor_Dataset_CANDIDATE.xlsx'),
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      true
    )
    post '/import', anchor_file: file

    expect(last_response.status).to eq(422)
    expect(last_response.body).to include('Schema validation failed')
    expect(last_response.body).to include("expected 'currency', got 'CURRENCY'")
    # DB unchanged
    expect(Customer.count).to eq(pre_count)
  end
end
