from random import randint
from unittest.mock import AsyncMock, Mock
from uuid import uuid4

import pytest
import pytest_asyncio
from push_notifications.models import APNSDevice, GCMDevice, WebPushDevice, WNSDevice

# from avant.messaging import Driver
from base_app.models import User
from notification_delivery.schemas import ThirdPartyNotificationRequest
from notification_delivery.utils import (
    construct_balance_exceed_message,
    construct_purchase_notification_message,
    convert_epoch_to_central_time,
)
from notification_events.management.commands.kafka_consumer import (
    get_user_devices,
)


class TestGetUserDevices:
    @pytest.fixture(scope="class")
    def mock_driver(self):
        mock_driver = Mock()
        mock_producer = AsyncMock()
        mock_producer.send = AsyncMock()
        mock_producer.flush = AsyncMock()
        mock_producer.close = AsyncMock()

        mock_driver.generate_producer.return_value = mock_producer
        return mock_driver

    @pytest_asyncio.fixture(scope="function")
    async def user_devices(self):
        # Create test user
        user = await User.objects.acreate(username="testuser", customer_uuid=uuid4())

        # Create test devices
        apns = await APNSDevice.objects.acreate(
            registration_id="apns_test_token", device_id=uuid4(), active=True
        )
        await apns.users.aadd(user)

        gcm = await GCMDevice.objects.acreate(
            registration_id="gcm_test_token",
            device_id=randint(1000, 9999),
            active=True,
        )
        await gcm.users.aadd(user)

        web = await WebPushDevice.objects.acreate(
            registration_id="web_test_token", active=True
        )
        await web.users.aadd(user)

        wns = await WNSDevice.objects.acreate(
            registration_id="wns_test_token", device_id=uuid4(), active=True
        )
        await wns.users.aadd(user)

        return {
            "user": user,
            "devices": {"apns": apns, "gcm": gcm, "web": web, "wns": wns},
        }

    @pytest.mark.asyncio
    @pytest.mark.django_db
    async def test_get_user_devices_returns_all_active_devices(
        self, mock_driver, user_devices
    ):
        """get_user_devices returns all devices associated with a user"""
        # Arrange
        devices = user_devices
        customer_uuid = devices["user"].customer_uuid

        # Act
        user_devices = await get_user_devices(customer_uuid)

        # Assert
        assert len(user_devices) == 4
        expected_devices = [device for device in devices["devices"].values()]
        assert set(user_devices) == set(expected_devices)

    @pytest.mark.django_db
    @pytest.mark.asyncio
    async def test_get_user_devices_returns_empty_list_when_no_devices(self):
        """get_user_devices returns an empty list when no devices are associated with a user"""
        # Arrange
        customer_uuid = str(uuid4())

        # Act
        devices = await get_user_devices(customer_uuid)

        # Assert
        assert len(devices) == 0


class TestPurchaseNotificationMessage:
    def test_construct_purchase_notification_message(self):
        """
        Test verifying that the purchase notification message is correctly constructed
        from the message_map fields: amount, merchant_name, and transaction_time.
        """
        # Arrange

        notification_request = ThirdPartyNotificationRequest.model_validate(
            dict(
                appToken="AvantAPI",
                deploymentToken="FDUSA2019",
                fiToken="1091AvantAPI",
                subscriberReferenceId="e150a3a1ondotd6d2sub42d0aded601b34617f6d-5-3-0-0",
                language="en-us",
                cardReferenceId="100106611",
                alertCategory="transaction",
                alertTypeCode="txn",
                message="Original verbose message from Fiserv",
                messageMap=dict(
                    amount=-2.75,
                    merchantName="Wikimedia",
                    transactionTime=1746118690000,  # Epoch time: 1746118690000 = May 1, 2025 11:58:10 AM CDT
                ),
                memberSequenceIdentifier="00001",
            )
        )

        # Convert epoch to expected formatted time
        expected_time = convert_epoch_to_central_time(1746118690000)

        # Act
        result = construct_purchase_notification_message(notification_request)

        # Assert
        expected_message = "Pending charge for ${:.2f} from {} at {} CT".format(
            abs(notification_request.message_map.amount),
            notification_request.message_map.merchant_name,
            expected_time,
        )
        assert result == expected_message
        # Verify the specific components are included in the message
        assert (
            str(abs(notification_request.message_map.amount)) in result
        )  # amount (absolute value of negative amount)
        assert notification_request.message_map.merchant_name in result  # merchant_name
        assert expected_time in result  # formatted transaction_time


class TestBalanceExceedNotificationMessage:
    def test_construct_balance_exceed_message_with_valid_balance(self):
        """
        Test verifying that the balance exceed notification message is correctly constructed
        when amount is provided and valid.
        """
        balance_threshold = 2500.00

        result = construct_balance_exceed_message(balance_threshold)

        expected_message = "Your balance just passed the $2500.00 alert you set. Manage your account with confidence - tap to review."
        assert result == expected_message
        assert "$2500.00" in result
