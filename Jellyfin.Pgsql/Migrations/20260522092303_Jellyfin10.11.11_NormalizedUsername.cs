using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Jellyfin.Plugin.Pgsql.Migrations;

/// <inheritdoc />
public partial class Jellyfin101111_NormalizedUsername : Migration
{
    /// <inheritdoc />
    protected override void Up(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.AddColumn<string>(
            name: "NormalizedUsername",
            table: "Users",
            type: "character varying(255)",
            maxLength: 255,
            nullable: false,
            defaultValue: string.Empty);
    }

    /// <inheritdoc />
    protected override void Down(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.DropColumn(
            name: "NormalizedUsername",
            table: "Users");
    }
}
