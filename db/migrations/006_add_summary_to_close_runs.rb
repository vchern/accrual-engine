Sequel.migration do
  change do
    alter_table(:close_runs) do
      add_column :summary, String, text: true
      add_column :summary_at, DateTime
      add_column :summary_model, String
    end
  end
end
