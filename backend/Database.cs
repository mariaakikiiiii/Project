using System.Data;
using Microsoft.Data.SqlClient;

public sealed class Database(IConfiguration config)
{
    private string ConnectionString => config.GetConnectionString("GameOn")
        ?? throw new InvalidOperationException("Configure ConnectionStrings__GameOn securely.");
    public static SqlParameter P(string name, SqlDbType type, object? value, int size = 0)
    {
        var p = new SqlParameter(name, type) { Value = value ?? DBNull.Value };
        if (size > 0) p.Size = size;
        return p;
    }
    public async Task<List<List<Dictionary<string, object?>>>> Call(
        string procedure, CancellationToken ct, params SqlParameter[] parameters)
    {
        await using var connection = new SqlConnection(ConnectionString);
        await connection.OpenAsync(ct);
        await using var command = new SqlCommand(procedure, connection)
        { CommandType = CommandType.StoredProcedure, CommandTimeout = 30 };
        command.Parameters.AddRange(parameters);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var sets = new List<List<Dictionary<string, object?>>>();
        do
        {
            var rows = new List<Dictionary<string, object?>>();
            while (await reader.ReadAsync(ct))
            {
                var row = new Dictionary<string, object?>();
                for (int i = 0; i < reader.FieldCount; i++)
                {
                    string name = reader.GetName(i);
                    row[char.ToLowerInvariant(name[0]) + name[1..]] =
                        await reader.IsDBNullAsync(i, ct) ? null : reader.GetValue(i);
                }
                rows.Add(row);
            }
            sets.Add(rows);
        } while (await reader.NextResultAsync(ct));
        return sets;
    }
}
