#nullable disable

#pragma warning disable CS1591

using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Jellyfin.Database.Implementations.Entities;
using MediaBrowser.Controller.Entities;
using MediaBrowser.Model.Dto;

namespace MediaBrowser.Controller.Library;

public interface IItemActionProvider
{
    Task<IReadOnlyList<ItemActionInfo>> GetActionsAsync(BaseItem item, User user, CancellationToken cancellationToken);

    Task<ItemActionResult> InvokeAsync(BaseItem item, User user, string actionId, ItemActionRequest request, CancellationToken cancellationToken);
}
