#nullable disable

#pragma warning disable CS1591

namespace MediaBrowser.Model.Dto;

public class ItemActionResult
{
    public bool Success { get; set; }

    public string Code { get; set; }

    public string Message { get; set; }

    public bool RefreshItem { get; set; } = true;
}
