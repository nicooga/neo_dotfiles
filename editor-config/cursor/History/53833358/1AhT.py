import asyncio
import logging
from datetime import datetime
from typing import Optional

import pytz
from asgiref.sync import sync_to_async
from firebase_admin import messaging
from push_notifications.models import APNSDevice, GCMDevice, WebPushDevice, WNSDevice

from notification_delivery.schemas import ThirdPartyNotificationRequest

logger = logging.getLogger(__name__)


def convert_epoch_to_central_time(epoch_ms: int) -> str:
    """
    Converts an epoch timestamp in milliseconds to Central Time

    Args:
        epoch_ms (int): The epoch timestamp in milliseconds

    Returns:
        str: The formatted date and time in Central Time (without seconds)
    """
    # Convert milliseconds to seconds (datetime expects seconds)
    epoch_seconds = epoch_ms / 1000

    # Create a UTC datetime object from the epoch timestamp
    utc_dt = datetime.utcfromtimestamp(epoch_seconds)

    # Make the datetime timezone-aware (UTC)
    utc_dt = pytz.utc.localize(utc_dt)

    # Convert to Central Time
    central_tz = pytz.timezone("America/Chicago")
    central_dt = utc_dt.astimezone(central_tz)

    # Format the datetime as a string (without seconds)
    formatted_time = central_dt.strftime("%B %d %Y, %I:%M %p")

    return formatted_time  # type: ignore[no-any-return,unused-ignore]


def construct_purchase_notification_message(
    notification_request: ThirdPartyNotificationRequest,
) -> str:
    """Given a ThirdPartyNotificationRequest, construct a purchase notification message for the user.
    Args:
        notification_request (ThirdPartyNotificationRequest): The notification request object.
    Returns:
        str: The constructed purchase notification message to be sent to the user.
    """
    if not notification_request.message_map:
        raise ValueError(
            "message_map field is required to construct a purchase notification message"
        )

    mm = notification_request.message_map
    if not (mm.amount and mm.merchant_name and mm.transaction_time):
        raise ValueError(
            "amount, merchant_name, and transaction_time fields are required to construct a purchase notification message"
        )

    formatted_time = convert_epoch_to_central_time(mm.transaction_time)
    message = f"Pending charge for ${abs(mm.amount):.2f} from {mm.merchant_name} at {formatted_time} CT"
    return message


def construct_balance_exceed_message(
    balance_threshold: int,
) -> str:
    return f"Your balance just passed the ${balance_threshold:.2f} alert you set. Manage your account with confidence - tap to review."


def create_android_push_message(
    title: str,
    body: str,
    deeplink_uri: Optional[str] = None,
    image_url: Optional[str] = None,
) -> messaging.Message:
    """
    Creates a Firebase Cloud Messaging message that displays correctly
    in both force-closed and running app states.

    Parameters:
    title (str): The notification title
    body (str): The notification body
    deeplink_uri (str, optional): The URL to deep link into the app
    image_url (str, optional): The URL for any image to include in the notification

    Returns:
    messaging.Message: Properly formatted FCM message
    """
    # Create the structured message_data
    message_data = {"title": title, "body": body}

    # Add optional fields only if they exist
    if image_url:
        message_data["attachmentUrl"] = image_url
    if deeplink_uri:
        message_data["deeplink_uri"] = deeplink_uri

    # Create Android-specific notification configuration
    # Omitting icon and channel_id to use defaults from manifest
    android_notification = messaging.AndroidNotification(
        body=body,
        title=title,
        image=image_url,
    )

    android_config = messaging.AndroidConfig(
        notification=android_notification, priority="high"
    )

    # Create the complete message
    message = messaging.Message(data=message_data, android=android_config)

    return message


async def get_devices(
    model: type[APNSDevice | GCMDevice | WebPushDevice | WNSDevice],
    customer_uuid: str,
) -> list[APNSDevice | GCMDevice | WebPushDevice | WNSDevice]:
    try:
        devices_list: list[
            APNSDevice | GCMDevice | WebPushDevice | WNSDevice
        ] = await sync_to_async(
            lambda: list(
                model.objects.filter(
                    users__customer_uuid=customer_uuid, active=True
                ).select_related("user")
            )
        )()
        return devices_list
    except Exception as e:
        logger.error(
            "Failed to query %s devices for customer %s: %s",
            model.__name__,
            customer_uuid,
            str(e),
        )
        return []


async def get_user_devices(
    customer_uuid: str,
) -> list[APNSDevice | GCMDevice | WebPushDevice | WNSDevice]:
    """Get all active push notification devices for a user

    Args:
        customer_uuid: UUID of the customer

    Returns:
        List of active devices across all push platforms
    """

    devices: tuple[
        list[APNSDevice | GCMDevice | WebPushDevice | WNSDevice] | Exception,
        list[APNSDevice | GCMDevice | WebPushDevice | WNSDevice] | Exception,
        list[APNSDevice | GCMDevice | WebPushDevice | WNSDevice] | Exception,
        list[APNSDevice | GCMDevice | WebPushDevice | WNSDevice] | Exception,
    ] = await asyncio.gather(
        get_devices(APNSDevice, customer_uuid),
        get_devices(GCMDevice, customer_uuid),
        get_devices(WebPushDevice, customer_uuid),
        get_devices(WNSDevice, customer_uuid),
        return_exceptions=True,  # Prevent one failure from cancelling all queries
    )

    # Filter out exceptions and combine successful results
    all_devices: list[APNSDevice | GCMDevice | WebPushDevice | WNSDevice] = []
    for device_list in devices:
        if not isinstance(device_list, Exception) and isinstance(device_list, list):
            # Type assertion to help mypy understand this is a list of devices
            device_list_typed: list[
                APNSDevice | GCMDevice | WebPushDevice | WNSDevice
            ] = device_list
            all_devices.extend(device_list_typed)

    # Combine all device types
    return all_devices
