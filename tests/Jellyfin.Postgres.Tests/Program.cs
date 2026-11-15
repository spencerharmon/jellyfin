using System.Data.Common;
using System.Diagnostics;
using System.Text.Json;
using Jellyfin.Data.Enums;
using Jellyfin.Database.Implementations;
using Jellyfin.Database.Implementations.Entities;
using Jellyfin.Database.Implementations.Enums;
using Jellyfin.Database.Implementations.Locking;
using Jellyfin.Plugin.Pgsql.Database;
using Jellyfin.Server.Implementations.Item;
using MediaBrowser.Controller;
using MediaBrowser.Controller.Configuration;
using MediaBrowser.Controller.Dto;
using MediaBrowser.Controller.Entities;
using MediaBrowser.Controller.Entities.Movies;
using MediaBrowser.Controller.Entities.TV;
using MediaBrowser.Controller.Library;
using MediaBrowser.Controller.LiveTv;
using MediaBrowser.Controller.Persistence;
using MediaBrowser.Model.Configuration;
using MediaBrowser.Model.Entities;
using MediaBrowser.Model.Globalization;
using MediaBrowser.Model.Querying;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Diagnostics;
using Microsoft.Extensions.Logging.Abstractions;
using Moq;
using Npgsql;

var connectionString = Environment.GetEnvironmentVariable("PHANTOM_TEST_POSTGRES")
    ?? throw new InvalidOperationException("Run scripts/tests/phantom-postgres-hot-queries.test.sh");
var cs = new NpgsqlConnectionStringBuilder(connectionString);
// Refuse production endpoints and existing databases BEFORE any schema or data writes.
if (cs.Host is not ("127.0.0.1" or "localhost" or "postgres")
    || cs.Username != "phantom_test" || cs.Database?.StartsWith("phantom_hot_queries_", StringComparison.Ordinal) != true)
{
    throw new InvalidOperationException("Only local/CI postgres, user phantom_test, database phantom_hot_queries_* are permitted.");
}

using var connection = new NpgsqlConnection(connectionString);
connection.Open();
using (var check = new NpgsqlCommand("SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_toast%' AND c.relkind IN ('r','p')", connection))
{
    Require((long)check.ExecuteScalar()! == 0, "Database must be fresh and empty; the harness never drops an existing database.");
}

var reportPath = Environment.GetEnvironmentVariable("PHANTOM_HOT_QUERY_REPORT")
    ?? "tests/Jellyfin.Postgres.Tests/artifacts/hot-queries.json";
Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(reportPath))!);
var capture = new QueryCapture();
var timings = new Dictionary<string, double>();
var passed = false;
var provider = new PgSqlDatabaseProvider(null!, NullLogger<PgSqlDatabaseProvider>.Instance);
foreach (var (key, value) in new Dictionary<string, string?>
{
    ["POSTGRES_HOST"] = cs.Host, ["POSTGRES_PORT"] = cs.Port.ToString(), ["POSTGRES_DB"] = cs.Database,
    ["POSTGRES_USER"] = cs.Username, ["POSTGRES_PASSWORD"] = cs.Password
})
{
    Environment.SetEnvironmentVariable(key, value);
}

var builder = new DbContextOptionsBuilder<JellyfinDbContext>();
provider.Initialise(builder, new Jellyfin.Database.Implementations.DbConfiguration.DatabaseConfigurationOptions { DatabaseType = "Jellyfin-PgSql" });
// One statement per EF write makes each captured command independently EXPLAINable.
builder.UseNpgsql(o => o.MaxBatchSize(1)).AddInterceptors(capture)
    .ConfigureWarnings(w => w.Ignore(RelationalEventId.PendingModelChangesWarning));
var factory = new ContextFactory(builder.Options, provider);
provider.DbContextFactory = factory;
var host = new Mock<IServerApplicationHost>();
host.Setup(h => h.ExpandVirtualPath(It.IsAny<string>())).Returns((string p) => p);
host.Setup(h => h.ReverseVirtualPath(It.IsAny<string>())).Returns((string p) => p);
var configuration = new Mock<IServerConfigurationManager>();
configuration.SetupGet(c => c.Configuration).Returns(new ServerConfiguration());
var types = new Mock<IItemTypeLookup>();
types.SetupGet(t => t.BaseItemKindNames).Returns(new Dictionary<BaseItemKind, string>
{
    [BaseItemKind.Movie] = typeof(Movie).FullName!, [BaseItemKind.Episode] = typeof(Episode).FullName!
});
BaseItem.ConfigurationManager = configuration.Object;
var library = new Mock<ILibraryManager>();
library.Setup(l => l.GetCollectionFolders(It.IsAny<BaseItem>())).Returns(() => []);
library.Setup(l => l.GetLibraryOptions(It.IsAny<BaseItem>())).Returns(new LibraryOptions());
BaseItem.LibraryManager = library.Object;
BaseItem.Logger = NullLogger<BaseItem>.Instance;
Video.RecordingsManager = Mock.Of<IRecordingsManager>();
var repository = new BaseItemRepository(factory, host.Object, types.Object, configuration.Object,
    NullLogger<BaseItemRepository>.Instance, Mock.Of<ILocalizationManager>());
BaseItem.ItemRepository = repository;

try
{
    using (var db = factory.CreateDbContext())
    {
        // Use the shipped PostgreSQL migrations, not SQLite-specific model DDL filters.
        // The upstream snapshot is newer than this fork; querying still uses the local model.
        db.Database.Migrate();
    }

    Measure("seed", () =>
    {
        using var db = factory.CreateDbContext();
        db.Database.SetCommandTimeout(600);
        for (var start = 1; start <= 4_000_000; start += 500_000)
        {
            Console.WriteLine($"Seeding ItemValues {start}..{start + 499_999}");
            db.Database.ExecuteSqlInterpolated($"""
            INSERT INTO "ItemValues" ("ItemValueId", "Type", "Value", "CleanValue")
            SELECT md5('value-' || n)::uuid, (n % 7)::integer, 'value-' || n, 'value-' || n
            FROM generate_series({start}, {start + 499_999}) n;
            """);
        }
        // Only bulk filler bypasses the repository; all measured fixture reads/writes use it.
        db.Database.ExecuteSqlInterpolated($"""
            INSERT INTO "BaseItems" ("Id", "Type", "Name", "SortName", "MediaType",
                "IsMovie", "IsLocked", "IsSeries", "IsRepeat", "IsInMixedFolder", "IsFolder", "IsVirtualItem")
            SELECT md5('item-' || n)::uuid,
                CASE WHEN n % 2 = 0 THEN {typeof(Movie).FullName!} ELSE {typeof(Episode).FullName!} END,
                'Filler ' || n, 'filler ' || n, 'Video',
                false, false, false, false, false, false, false
            FROM generate_series(1, 20000) n;
            INSERT INTO "BaseItemProviders" ("ItemId", "ProviderId", "ProviderValue")
            SELECT md5('item-' || n)::uuid, 'Tmdb', 'filler-' || n
            FROM generate_series(1, 20000) n;
            INSERT INTO "BaseItemImageInfos" ("Id", "ItemId", "Path", "ImageType", "Width", "Height")
            SELECT md5('image-' || n)::uuid, md5('item-' || n)::uuid, '/fixture/' || n || '.jpg', 0, 640, 360
            FROM generate_series(1, 20000) n;
            """);

        db.Database.ExecuteSqlRaw("ANALYZE");
        Require(db.ItemValues.LongCount() >= 4_000_000, "4M ItemValues seed");
        Require(db.BaseItems.Count() >= 20_000 && db.BaseItemProviders.Count() == 20_000 && db.BaseItemImageInfos.Count() == 20_000, "20k item/provider/image seed");
    });

    var movie = new Movie { Id = Guid.NewGuid(), Name = "Fixture Movie", SortName = "fixture movie", ProductionYear = 2024 };
    var episode = new Episode { Id = Guid.NewGuid(), Name = "Fixture Episode", SortName = "fixture episode", IndexNumber = 3, ParentIndexNumber = 2, SeriesName = "Fixture Series" };
    BaseItem[] fixtures = [movie, episode];
    foreach (var item in fixtures)
    {
        item.Path = $"/fixture/{item.Id}.mkv";
        item.Genres = ["Drama", "Shared+Value"];
        item.Studios = ["Shared+Value"];
        item.Tags = ["Regression", "tag:with+delimiters"];
        item.ProviderIds = new Dictionary<string, string> { ["Tmdb"] = item == movie ? "movie:42" : "episode:43", ["Imdb"] = item == movie ? "tt42" : "tt43" };
        item.ImageInfos = [new ItemImageInfo { Path = $"/fixture/{item.Id}.jpg", Type = ImageType.Primary, Width = 640, Height = 360, BlurHash = "fixture-hash", DateModified = new DateTime(2024, 1, 1, 0, 0, 0, DateTimeKind.Utc) }];
    }

    capture.Phase = "SaveItems-insert";
    Measure(capture.Phase, () => repository.SaveItems(fixtures, CancellationToken.None));
    Verify(fixtures);
    movie.Name = "Updated Movie";
    movie.Tags = ["Updated", "tag:with+delimiters"];
    capture.Phase = "SaveItems-update";
    Measure(capture.Phase, () => repository.SaveItems(fixtures, CancellationToken.None));
    Verify(fixtures);
    movie.ImageInfos[0].Path = "/fixture/replaced.jpg";
    movie.ImageInfos[0].Width = 1280;
    capture.Phase = "SaveImages";
    Measure(capture.Phase, () => repository.SaveImages(movie));
    Verify(fixtures);

    foreach (var item in fixtures)
    {
        capture.Phase = "provider-selected";
        var query = Query();
        query.HasAnyProviderId = new Dictionary<string, string> { ["Tmdb"] = item.ProviderIds["Tmdb"] };
        Measure($"provider-{item.GetType().Name}", () =>
        {
            Require(repository.GetItemIdsList(query).SequenceEqual([item.Id]), "provider ID selection");
            var selected = repository.GetItemList(query);
            Require(selected.Count == 1 && selected[0].Id == item.Id, "provider item selection");
            CheckItem(item, selected[0]);
        });
    }

    capture.Phase = "provider-selected";
    var multiple = Query();
    multiple.HasAnyProviderId = new Dictionary<string, string> { ["Tmdb"] = "movie:42", ["Imdb"] = "tt43" };
    Require(repository.GetItemIdsList(multiple).ToHashSet().SetEquals(fixtures.Select(i => i.Id)), "multiple selected providers are OR, not AND");
    multiple.HasAnyProviderId = new Dictionary<string, string> { ["Tmdb"] = "movie:42", ["Imdb"] = "" };
    Require(repository.GetItemIdsList(multiple).SequenceEqual([movie.Id]), "provider-name and selected groups retain AND semantics");
    multiple.HasAnyProviderId = new Dictionary<string, string> { ["Tmdb"] = "missing" };
    Require(repository.GetItemIdsList(multiple).Count == 0, "missing provider");
    capture.Phase = "provider-excluded";
    var excluded = Query();
    excluded.ItemIds = fixtures.Select(i => i.Id).ToArray();
    excluded.ExcludeProviderIds = new Dictionary<string, string> { ["Tmdb"] = "movie:42" };
    Require(repository.GetItemIdsList(excluded).SequenceEqual([episode.Id]), "exact provider exclusion");

    capture.Phase = "browse";
    var browse = Query();
    browse.IncludeItemTypes = [BaseItemKind.Movie];
    browse.Limit = 20;
    browse.OrderBy = [(ItemSortBy.SortName, SortOrder.Ascending)];
    Measure("browse", () => Require(repository.GetItemList(browse).Count == 20, "representative movie browse"));

    Require(capture.Commands.Any(c => c.Target == "ItemValues"), "captured actual SaveItems ItemValues lookup");
    Require(capture.Commands.Any(c => c.Phase == "provider-selected" && c.Target == "BaseItemProviders"), "captured actual selected provider query");
    Require(capture.Commands.Any(c => c.Phase == "SaveImages" && c.Sql.StartsWith("DELETE", StringComparison.Ordinal)), "captured actual SaveImages delete");
    var regressions = capture.Commands.Where(c => c.SequentialScan).ToArray();
    foreach (var regression in regressions)
    {
        Console.WriteLine($"SEQ SCAN: {regression.Phase} / {regression.Target}, {regression.ExecutionMs:F3} ms");
    }

    Require(regressions.Length == 0, "selective hot queries must not sequentially scan targeted tables");
    foreach (var command in capture.Commands.Where(c => c.Target != null))
    {
        Console.WriteLine($"INDEXED: {command.Phase} / {command.Target}, {command.ExecutionMs:F3} ms");
        Require(command.ExecutionMs < 5, "selective lookup execution must remain below 5ms");
    }
    passed = true;
    Console.WriteLine("PASS: repository parity and selective PostgreSQL plans");
}
finally
{
    File.WriteAllText(reportPath, JsonSerializer.Serialize(new { Passed = passed, PostgreSQL = connection.PostgreSqlVersion.ToString(), ItemValuesSeed = 4_000_000, BaseItemsSeed = 20_000, TimingsMs = timings, Commands = capture.Commands }, new JsonSerializerOptions { WriteIndented = true }));
    Console.WriteLine($"Report: {reportPath}");
}

void Measure(string name, Action action)
{
    var watch = Stopwatch.StartNew();
    action();
    timings[name] = watch.Elapsed.TotalMilliseconds;
    Console.WriteLine($"{name}: {watch.Elapsed.TotalMilliseconds:F3} ms (includes diagnostic EXPLAIN overhead)");
}

void Verify(BaseItem[] expected)
{
    capture.Phase = "read-parity";
    var query = Query();
    query.ItemIds = expected.Select(i => i.Id).ToArray();
    var actual = repository.GetItemList(query).ToDictionary(i => i.Id);
    Require(actual.Count == expected.Length, "read item count");
    Require(repository.GetItemIdsList(query).ToHashSet().SetEquals(expected.Select(i => i.Id)), "ID/item parity");
    foreach (var item in expected)
    {
        CheckItem(item, actual[item.Id]);
        using var db = factory.CreateDbContext();
        var mapped = db.ItemValuesMap.Where(m => m.ItemId == item.Id).Select(m => new { m.ItemValue.Type, m.ItemValue.Value }).ToArray();
        var values = item.Genres.Select(v => (2, v)).Concat(item.Studios.Select(v => (3, v))).Concat(item.Tags.Select(v => (4, v))).Concat(item.GetInheritedTags().Select(v => (6, v))).ToHashSet();
        Require(mapped.Select(m => ((int)m.Type, m.Value)).ToHashSet().SetEquals(values), "typed ItemValues write/read parity");
        Require(mapped.Length == values.Count, "no duplicate ItemValues mappings after update");
    }
}

static InternalItemsQuery Query() => new()
{
    GroupByPresentationUniqueKey = false,
    EnableTotalRecordCount = false,
    DtoOptions = new DtoOptions(false) { Fields = [ItemFields.ProviderIds], EnableImages = true, EnableUserData = false }
};

static void CheckItem(BaseItem expected, BaseItem actual)
{
    Require(actual.GetType() == expected.GetType() && actual.Name == expected.Name && actual.Path == expected.Path, "movie/episode identity fields");
    Require(actual.Genres.SequenceEqual(expected.Genres) && actual.Studios.SequenceEqual(expected.Studios) && actual.Tags.SequenceEqual(expected.Tags), "value fields");
    Require(actual.ProviderIds.OrderBy(p => p.Key).SequenceEqual(expected.ProviderIds.OrderBy(p => p.Key)), "provider fields");
    Require(actual.ImageInfos.Length == expected.ImageInfos.Length, "image count");
    var image = actual.ImageInfos.Single();
    var wanted = expected.ImageInfos.Single();
    Require(image.Path == wanted.Path && image.Width == wanted.Width && image.Height == wanted.Height && image.Type == wanted.Type && image.BlurHash == wanted.BlurHash && image.DateModified == wanted.DateModified, "image fields");
    Require(actual.ProductionYear == expected.ProductionYear && actual.IndexNumber == expected.IndexNumber && actual.ParentIndexNumber == expected.ParentIndexNumber, "movie/episode metadata");
    if (actual is Episode episode && expected is Episode wantedEpisode)
    {
        Require(episode.SeriesName == wantedEpisode.SeriesName, "episode series metadata");
    }
}

static void Require(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException("FAIL: " + message);
}

sealed class ContextFactory(DbContextOptions<JellyfinDbContext> options, PgSqlDatabaseProvider provider) : IDbContextFactory<JellyfinDbContext>
{
    public JellyfinDbContext CreateDbContext() => new(options, NullLogger<JellyfinDbContext>.Instance, provider, new NoLockBehavior(NullLogger<NoLockBehavior>.Instance));
}

sealed record CommandReport(string Phase, string Sql, object[] Parameters, string? Target, bool SequentialScan, double ExecutionMs, JsonElement Plan);

sealed class QueryCapture : DbCommandInterceptor
{
    public string? Phase { get; set; }
    public List<CommandReport> Commands { get; } = [];

    public override InterceptionResult<DbDataReader> ReaderExecuting(DbCommand command, CommandEventData eventData, InterceptionResult<DbDataReader> result)
    {
        Explain(command);
        return result;
    }

    public override InterceptionResult<int> NonQueryExecuting(DbCommand command, CommandEventData eventData, InterceptionResult<int> result)
    {
        Explain(command);
        return result;
    }

    public override InterceptionResult<object> ScalarExecuting(DbCommand command, CommandEventData eventData, InterceptionResult<object> result)
    {
        Explain(command);
        return result;
    }

    private void Explain(DbCommand command)
    {
        if (Phase is null) return;
        var source = (NpgsqlCommand)command;
        var sql = source.CommandText;
        if (!(sql.StartsWith("SELECT", StringComparison.Ordinal) || sql.StartsWith("INSERT", StringComparison.Ordinal) || sql.StartsWith("UPDATE", StringComparison.Ordinal) || sql.StartsWith("DELETE", StringComparison.Ordinal))) return;
        var target = Phase.StartsWith("SaveItems", StringComparison.Ordinal) && sql.StartsWith("SELECT", StringComparison.Ordinal) && sql.Contains("FROM \"ItemValues\"", StringComparison.Ordinal)
            ? "ItemValues"
            : Phase == "provider-selected" ? "BaseItemProviders"
            : Phase == "SaveImages" && sql.StartsWith("DELETE", StringComparison.Ordinal) ? "BaseItemImageInfos" : null;
        // Explain BEFORE execution, on the same connection and data snapshot. Rolling back a
        // savepoint lets INSERT/UPDATE/DELETE execute genuinely without altering the real call.
        using var owned = source.Transaction is null ? source.Connection!.BeginTransaction() : null;
        var transaction = source.Transaction ?? owned!;
        transaction.Save("phantom_explain");
        try
        {
            using var explain = new NpgsqlCommand("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " + sql, source.Connection, transaction) { CommandTimeout = 120 };
            foreach (NpgsqlParameter parameter in source.Parameters)
            {
                explain.Parameters.Add(parameter.Clone());
            }

            var json = (string)explain.ExecuteScalar()!;
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement[0];
            var sequential = target is not null && HasSequentialScan(root.GetProperty("Plan"), target);
            Commands.Add(new CommandReport(Phase, sql, source.Parameters.Cast<NpgsqlParameter>().Select(p => (object)new { p.ParameterName, Type = p.NpgsqlDbType.ToString(), p.DataTypeName, p.Value }).ToArray(), target, sequential, root.GetProperty("Execution Time").GetDouble(), root.Clone()));
        }
        finally
        {
            transaction.Rollback("phantom_explain");
            transaction.Release("phantom_explain");
            owned?.Rollback();
        }
    }

    private static bool HasSequentialScan(JsonElement node, string target)
    {
        if (node.TryGetProperty("Relation Name", out var relation) && relation.GetString() == target
            && node.GetProperty("Node Type").GetString() is "Seq Scan" or "Parallel Seq Scan") return true;
        return node.TryGetProperty("Plans", out var plans) && plans.EnumerateArray().Any(p => HasSequentialScan(p, target));
    }
}
