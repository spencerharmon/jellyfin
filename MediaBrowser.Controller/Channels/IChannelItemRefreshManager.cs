#nullable disable

#pragma warning disable CS1591

using System;
using System.Threading;
using System.Threading.Tasks;

namespace MediaBrowser.Controller.Channels
{
    /// <summary>
    /// Refreshes a single channel item's persisted state from its
    /// providing <see cref="IChannel"/>. Used by plugins that mutate a
    /// channel item's underlying media independently of the regular
    /// channel scan (e.g. materialise-on-demand pipelines where a
    /// placeholder MediaSource is replaced by a real file).
    ///
    /// Implemented by <c>ChannelManager</c>; registered as a sibling
    /// service to <see cref="IChannelManager"/>. Adding this as a new
    /// interface (rather than extending <see cref="IChannelManager"/>)
    /// preserves binary compatibility for existing plugins.
    /// </summary>
    public interface IChannelItemRefreshManager
    {
        /// <summary>
        /// Refresh a single channel item's persisted state.
        /// </summary>
        /// <param name="channelId">
        /// The internal Jellyfin channel id (the <see cref="Channel"/>
        /// BaseItem id, not the external channel-provider name).
        /// </param>
        /// <param name="channelItemExternalId">
        /// The external id (<see cref="ChannelItemInfo.Id"/>) of the
        /// item to refresh.
        /// </param>
        /// <param name="options">
        /// Refresh options. If <c>null</c>, defaults to all flags true.
        /// </param>
        /// <param name="cancellationToken">Cancellation token.</param>
        /// <returns>A task representing the operation.</returns>
        Task RefreshChannelItemAsync(
            Guid channelId,
            string channelItemExternalId,
            ChannelItemRefreshOptions options = null,
            CancellationToken cancellationToken = default);
    }

    /// <summary>
    /// Flags controlling <see cref="IChannelItemRefreshManager.RefreshChannelItemAsync"/>
    /// behaviour.
    /// </summary>
    public sealed class ChannelItemRefreshOptions
    {
        /// <summary>
        /// Gets or sets a value indicating whether to force the channel
        /// item's persisted fields (Path, MediaSources, RunTimeTicks) to
        /// be re-written from the refreshed <see cref="ChannelItemInfo"/>
        /// even if the item already exists.
        /// </summary>
        public bool ForceUpdate { get; set; } = true;

        /// <summary>
        /// Gets or sets a value indicating whether to force a full
        /// metadata refresh including remote content probe (codec/stream
        /// re-detection) for the refreshed item.
        /// </summary>
        public bool ForceProbe { get; set; } = true;

        /// <summary>
        /// Gets or sets a value indicating whether to invalidate the
        /// in-memory MediaSources cache so the next playback request
        /// re-queries the channel.
        /// </summary>
        public bool InvalidateMediaInfoCache { get; set; } = true;
    }
}
