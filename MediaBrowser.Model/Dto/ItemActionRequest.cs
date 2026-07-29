#nullable disable

#pragma warning disable CS1591

using System.Text.Json.Nodes;

namespace MediaBrowser.Model.Dto;

public class ItemActionRequest
{
    public JsonObject Payload { get; set; }
}
