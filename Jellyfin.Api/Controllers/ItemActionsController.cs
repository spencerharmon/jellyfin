using System;
using System.Collections.Generic;
using System.ComponentModel.DataAnnotations;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Jellyfin.Api.Extensions;
using MediaBrowser.Controller.Entities;
using MediaBrowser.Controller.Library;
using MediaBrowser.Model.Dto;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;

namespace Jellyfin.Api.Controllers;

/// <summary>
/// Server-advertised item actions supplied by plugins and core providers.
/// </summary>
[ApiController]
[Authorize]
[Route("Items/{itemId}/Actions")]
[Produces("application/json")]
public class ItemActionsController : BaseJellyfinApiController
{
    private readonly ILibraryManager _libraryManager;
    private readonly IUserManager _userManager;
    private readonly IEnumerable<IItemActionProvider> _providers;

    /// <summary>
    /// Initializes a new instance of the <see cref="ItemActionsController"/> class.
    /// </summary>
    /// <param name="libraryManager">Library manager.</param>
    /// <param name="userManager">User manager.</param>
    /// <param name="providers">Registered item action providers.</param>
    public ItemActionsController(
        ILibraryManager libraryManager,
        IUserManager userManager,
        IEnumerable<IItemActionProvider> providers)
    {
        _libraryManager = libraryManager;
        _userManager = userManager;
        _providers = providers;
    }

    /// <summary>
    /// Gets item actions available to the current user.
    /// </summary>
    /// <param name="itemId">The item id.</param>
    /// <param name="userId">Optional user id, required when authenticated with an API key.</param>
    /// <param name="cancellationToken">Cancellation token.</param>
    /// <returns>Available actions.</returns>
    [HttpGet]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<IReadOnlyList<ItemActionInfo>>> GetActions(
        [FromRoute, Required] string itemId,
        [FromQuery] Guid? userId,
        CancellationToken cancellationToken = default)
    {
        if (!TryParseItemId(itemId, out var parsedItemId))
        {
            return BadRequest("Invalid item id");
        }

        var requestUserId = ResolveUserId(userId);
        if (requestUserId.Equals(Guid.Empty))
        {
            return BadRequest("userId query parameter is required when the authentication token is not user-scoped");
        }

        var user = _userManager.GetUserById(requestUserId);
        if (user is null)
        {
            return NotFound();
        }

        var item = _libraryManager.GetItemById<BaseItem>(parsedItemId, requestUserId);
        if (item is null)
        {
            return NotFound();
        }

        var actions = new List<ItemActionInfo>();
        foreach (var provider in _providers)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var provided = await provider.GetActionsAsync(item, user, cancellationToken).ConfigureAwait(false);
            if (provided.Count > 0)
            {
                actions.AddRange(provided);
            }
        }

        return Ok((IReadOnlyList<ItemActionInfo>)actions.ToArray());
    }

    /// <summary>
    /// Invokes an item action.
    /// </summary>
    /// <param name="itemId">The item id.</param>
    /// <param name="actionId">The action id.</param>
    /// <param name="userId">Optional user id, required when authenticated with an API key.</param>
    /// <param name="request">Optional action payload.</param>
    /// <param name="cancellationToken">Cancellation token.</param>
    /// <returns>Action result.</returns>
    [HttpPost("{actionId}")]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    [ProducesResponseType(StatusCodes.Status409Conflict)]
    [ProducesResponseType(StatusCodes.Status422UnprocessableEntity)]
    [ProducesResponseType(StatusCodes.Status500InternalServerError)]
    public async Task<ActionResult<ItemActionResult>> InvokeAction(
        [FromRoute, Required] string itemId,
        [FromRoute, Required] string actionId,
        [FromQuery] Guid? userId,
        [FromBody] ItemActionRequest? request,
        CancellationToken cancellationToken = default)
    {
        if (!TryParseItemId(itemId, out var parsedItemId))
        {
            return BadRequest("Invalid item id");
        }

        var requestUserId = ResolveUserId(userId);
        if (requestUserId.Equals(Guid.Empty))
        {
            return BadRequest("userId query parameter is required when the authentication token is not user-scoped");
        }

        var user = _userManager.GetUserById(requestUserId);
        if (user is null)
        {
            return NotFound();
        }

        var item = _libraryManager.GetItemById<BaseItem>(parsedItemId, requestUserId);
        if (item is null)
        {
            return NotFound();
        }

        foreach (var provider in _providers)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var actions = await provider.GetActionsAsync(item, user, cancellationToken).ConfigureAwait(false);
            if (!actions.Any(a => string.Equals(a.Id, actionId, StringComparison.Ordinal)))
            {
                continue;
            }

            var action = actions.First(a => string.Equals(a.Id, actionId, StringComparison.Ordinal));
            if (!action.IsEnabled)
            {
                return Conflict(new ItemActionResult
                {
                    Success = false,
                    Code = "action_disabled",
                    Message = "Action is currently disabled",
                    RefreshItem = false,
                });
            }

            var result = await provider.InvokeAsync(item, user, actionId, request ?? new ItemActionRequest(), cancellationToken).ConfigureAwait(false);
            if (result.Success)
            {
                return Ok(result);
            }

            return result.Code switch
            {
                "not_found" or "candidate_not_found" => NotFound(result),
                "in_flight" or "no_current" or "action_disabled" => Conflict(result),
                "no_alternate" or "unavailable" => UnprocessableEntity(result),
                _ => StatusCode(StatusCodes.Status500InternalServerError, result),
            };
        }

        return NotFound(new ItemActionResult
        {
            Success = false,
            Code = "action_not_found",
            Message = "Action not found",
            RefreshItem = false,
        });
    }

    private Guid ResolveUserId(Guid? requestedUserId)
    {
        var authenticatedUserId = User.GetUserId();
        if (requestedUserId is null || requestedUserId.Value.Equals(Guid.Empty))
        {
            return authenticatedUserId;
        }

        if (!authenticatedUserId.Equals(Guid.Empty) && !authenticatedUserId.Equals(requestedUserId.Value))
        {
            throw new UnauthorizedAccessException("Requested user id does not match authenticated user");
        }

        return requestedUserId.Value;
    }

    private static bool TryParseItemId(string itemId, out Guid parsedItemId)
        => Guid.TryParse(itemId, out parsedItemId)
            || Guid.TryParseExact(itemId, "N", out parsedItemId);
}
