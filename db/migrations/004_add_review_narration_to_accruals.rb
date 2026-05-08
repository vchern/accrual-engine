Sequel.migration do
  change do
    alter_table(:accruals) do
      add_column :review_narration, String, text: true
      add_column :review_narration_at, DateTime
      add_column :review_narration_model, String
    end
  end
end
