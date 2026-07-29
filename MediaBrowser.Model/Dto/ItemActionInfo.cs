#nullable disable

#pragma warning disable CS1591

namespace MediaBrowser.Model.Dto;

public class ItemActionInfo
{
    public string Id { get; set; }

    public string Name { get; set; }

    public string Description { get; set; }

    public string Icon { get; set; }

    public bool IsEnabled { get; set; } = true;

    public bool RequiresConfirmation { get; set; }

    public string ConfirmationText { get; set; }

    public bool RefreshItemAfterInvoke { get; set; } = true;
}
