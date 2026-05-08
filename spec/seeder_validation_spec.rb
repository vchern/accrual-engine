require 'spec_helper'

RSpec.describe Seeder, '.validate!' do
  let(:anchor_path) { File.join(ROOT, 'Helix_Anchor_Dataset_CANDIDATE.xlsx') }

  it 'returns true for the bundled anchor (every sheet matches the schema)' do
    expect(described_class.validate!(path: anchor_path)).to be true
  end

  it 'raises SchemaError listing missing files' do
    expect { described_class.validate!(path: '/no/such/file.xlsx') }
      .to raise_error(Seeder::SchemaError, /File not found/)
  end

  it 'raises SchemaError when a sheet is missing' do
    fake_xlsx = instance_double(Roo::Excelx)
    allow(Roo::Excelx).to receive(:new).and_return(fake_xlsx)
    allow(fake_xlsx).to receive(:sheet) do |name|
      next nil if name == 'customers'
      stub_sheet_for(name)
    end

    expect { described_class.validate!(path: anchor_path) }
      .to raise_error(Seeder::SchemaError) { |e|
        expect(e.errors).to include(a_string_matching(/Missing sheet: 'customers'/))
      }
  end

  it 'raises SchemaError when a column is renamed' do
    fake_xlsx = instance_double(Roo::Excelx)
    allow(Roo::Excelx).to receive(:new).and_return(fake_xlsx)
    allow(fake_xlsx).to receive(:sheet) do |name|
      if name == 'customers'
        broken = instance_double('Roo::Sheet')
        allow(broken).to receive(:row).with(1)
          .and_return(%w[customer_id name CURRENCY country status billing_anchor])
        broken
      else
        stub_sheet_for(name)
      end
    end

    expect { described_class.validate!(path: anchor_path) }
      .to raise_error(Seeder::SchemaError) { |e|
        expect(e.errors).to include(a_string_matching(/Sheet 'customers'.*expected 'currency'.*got 'CURRENCY'/))
      }
  end

  it 'raises SchemaError when columns are swapped' do
    fake_xlsx = instance_double(Roo::Excelx)
    allow(Roo::Excelx).to receive(:new).and_return(fake_xlsx)
    allow(fake_xlsx).to receive(:sheet) do |name|
      if name == 'customers'
        broken = instance_double('Roo::Sheet')
        # currency and country swapped
        allow(broken).to receive(:row).with(1)
          .and_return(%w[customer_id name country currency status billing_anchor])
        broken
      else
        stub_sheet_for(name)
      end
    end

    expect { described_class.validate!(path: anchor_path) }
      .to raise_error(Seeder::SchemaError) { |e|
        expect(e.errors.size).to be >= 2  # both column 3 and 4 disagree
      }
  end

  def stub_sheet_for(name)
    cols = Seeder::SHEET_SCHEMA.fetch(name)
    sheet = instance_double('Roo::Sheet')
    allow(sheet).to receive(:row).with(1).and_return(cols)
    sheet
  end
end
