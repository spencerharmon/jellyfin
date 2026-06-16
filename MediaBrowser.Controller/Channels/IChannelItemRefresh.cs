#nullable disable

#pragma warning disable CS1591

using System.Threading;
using System.Threading.Tasks;

namespace MediaBrowser.Controller.Channels
{
    /// <summary>
    /// Optional capability for <see cref="IChannel"/> implementations.
    /// Channels that implement this advertise the ability to resolve a
    /// single <see cref="ChannelItemInfo"/> by its external id without
    /// paging through <see cref="IChannel.GetChannelItems"/>. Used by
    /// <see cref="IChannelItemRefreshManager.RefreshChannelItemAsync"/>
    /// for efficient single-item refresh when a plugin-driven workflow
    /// (e.g. materialise-on-demand) needs to update a single item's
    /// persisted state.
    ///
    /// Channels that do not implement this interface fall back to the
    /// manager paging through <c>GetChannelItems</c> to locate the item.
    /// </summary>
    public interface IChannelItemRefresh
    {
        /// <summary>
        /// Look up the current <see cref="ChannelItemInfo"/> for a given
        /// external id.
        /// </summary>
        /// <param name="channelItemExternalId">
        /// The external id (i.e. <see cref="ChannelItemInfo.Id"/>) of the
        /// item to resolve.
        /// </param>
        /// <param name="cancellationToken">Cancellation token.</param>
        /// <returns>
        /// The current <see cref="ChannelItemInfo"/> for the given id, or
        /// <c>null</c> if the channel no longer surfaces that item.
        /// </returns>
        Task<ChannelItemInfo> GetChannelItemAsync(
            string channelItemExternalId,
            CancellationToken cancellationToken);
    }
}
