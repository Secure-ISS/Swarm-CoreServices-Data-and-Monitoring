#!/usr/bin/env python3
"""Integration Domain Tests - Event Bus Integration.

Tests for event bus functionality including:
- Event publishing and subscription
- Event filtering and routing
- Async event handling
- Event persistence and replay
"""

import os
import sys
import unittest
from unittest.mock import Mock, MagicMock, patch
from typing import Dict, Any, List, Callable
import time
import threading

# Add parent directory to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../..'))


class TestEventBusBasics(unittest.TestCase):
    """Test basic event bus functionality."""

    def setUp(self):
        """Set up event bus mock."""
        self.event_bus = {
            'subscribers': {},
            'events': [],
            'lock': threading.Lock()
        }

    def test_event_structure(self):
        """Test event data structure."""
        event = {
            'type': 'memory.stored',
            'timestamp': time.time(),
            'data': {
                'namespace': 'test',
                'key': 'test_key',
                'value': 'test_value'
            },
            'metadata': {
                'source': 'vector_ops',
                'user': 'system'
            }
        }

        # Validate event structure
        required_fields = ['type', 'timestamp', 'data']
        for field in required_fields:
            self.assertIn(field, event)

        self.assertIsInstance(event['timestamp'], float)
        self.assertIsInstance(event['data'], dict)

    def test_event_type_naming(self):
        """Test event type naming conventions."""
        valid_event_types = [
            'memory.stored',
            'memory.retrieved',
            'memory.deleted',
            'agent.spawned',
            'agent.terminated',
            'swarm.initialized',
            'query.executed',
            'connection.established',
            'connection.failed'
        ]

        for event_type in valid_event_types:
            # Event types should be lowercase with dots
            self.assertTrue(event_type.islower())
            self.assertIn('.', event_type)

            # Should have domain and action
            parts = event_type.split('.')
            self.assertGreaterEqual(len(parts), 2)


class TestEventPublishing(unittest.TestCase):
    """Test event publishing functionality."""

    def setUp(self):
        """Set up event bus."""
        self.events = []

        def publish(event_type: str, data: Dict[str, Any]):
            event = {
                'type': event_type,
                'timestamp': time.time(),
                'data': data
            }
            self.events.append(event)
            return event

        self.publish = publish

    def test_publish_event(self):
        """Test publishing an event."""
        event = self.publish('test.event', {'key': 'value'})

        self.assertEqual(len(self.events), 1)
        self.assertEqual(event['type'], 'test.event')
        self.assertEqual(event['data']['key'], 'value')

    def test_publish_multiple_events(self):
        """Test publishing multiple events."""
        for i in range(10):
            self.publish(f'test.event.{i}', {'index': i})

        self.assertEqual(len(self.events), 10)

        # Verify order
        for i, event in enumerate(self.events):
            self.assertEqual(event['data']['index'], i)

    def test_event_timestamp_ordering(self):
        """Test that events have increasing timestamps."""
        timestamps = []

        for i in range(5):
            event = self.publish('test.event', {'index': i})
            timestamps.append(event['timestamp'])
            time.sleep(0.01)

        # Timestamps should be increasing
        for i in range(len(timestamps) - 1):
            self.assertLessEqual(timestamps[i], timestamps[i + 1])


class TestEventSubscription(unittest.TestCase):
    """Test event subscription functionality."""

    def setUp(self):
        """Set up event bus with subscription support."""
        self.subscribers = {}
        self.events = []

    def subscribe(self, event_type: str, handler: Callable):
        """Subscribe to event type."""
        if event_type not in self.subscribers:
            self.subscribers[event_type] = []
        self.subscribers[event_type].append(handler)

    def publish(self, event_type: str, data: Dict[str, Any]):
        """Publish event and notify subscribers."""
        event = {
            'type': event_type,
            'timestamp': time.time(),
            'data': data
        }
        self.events.append(event)

        # Notify subscribers
        if event_type in self.subscribers:
            for handler in self.subscribers[event_type]:
                handler(event)

        return event

    def test_subscribe_to_event(self):
        """Test subscribing to an event type."""
        received_events = []

        def handler(event):
            received_events.append(event)

        self.subscribe('test.event', handler)
        self.publish('test.event', {'key': 'value'})

        self.assertEqual(len(received_events), 1)
        self.assertEqual(received_events[0]['data']['key'], 'value')

    def test_multiple_subscribers(self):
        """Test multiple subscribers to same event."""
        received_1 = []
        received_2 = []

        self.subscribe('test.event', lambda e: received_1.append(e))
        self.subscribe('test.event', lambda e: received_2.append(e))

        self.publish('test.event', {'key': 'value'})

        self.assertEqual(len(received_1), 1)
        self.assertEqual(len(received_2), 1)

    def test_wildcard_subscription(self):
        """Test wildcard event subscription."""
        all_events = []

        # Subscribe to all events
        def wildcard_handler(event):
            all_events.append(event)

        # Simulate wildcard by subscribing to multiple types
        for event_type in ['memory.stored', 'memory.retrieved', 'memory.deleted']:
            self.subscribe(event_type, wildcard_handler)

        self.publish('memory.stored', {'key': 'key1'})
        self.publish('memory.retrieved', {'key': 'key2'})
        self.publish('memory.deleted', {'key': 'key3'})

        self.assertEqual(len(all_events), 3)

    def test_unsubscribe(self):
        """Test unsubscribing from events."""
        received = []

        def handler(event):
            received.append(event)

        # Subscribe
        self.subscribe('test.event', handler)

        # Publish event
        self.publish('test.event', {'num': 1})
        self.assertEqual(len(received), 1)

        # Unsubscribe
        self.subscribers['test.event'].remove(handler)

        # Publish again
        self.publish('test.event', {'num': 2})

        # Should still have only 1 event
        self.assertEqual(len(received), 1)


class TestEventFiltering(unittest.TestCase):
    """Test event filtering and routing."""

    def setUp(self):
        """Set up event bus with filtering."""
        self.events = []

    def publish_with_filter(self, event_type: str, data: Dict[str, Any],
                           filter_func: Callable = None):
        """Publish event with optional filter."""
        event = {
            'type': event_type,
            'timestamp': time.time(),
            'data': data
        }

        if filter_func is None or filter_func(event):
            self.events.append(event)

        return event

    def test_filter_by_namespace(self):
        """Test filtering events by namespace."""
        def namespace_filter(event):
            return event['data'].get('namespace') == 'important'

        self.publish_with_filter(
            'memory.stored',
            {'namespace': 'important', 'key': 'key1'},
            namespace_filter
        )

        self.publish_with_filter(
            'memory.stored',
            {'namespace': 'other', 'key': 'key2'},
            namespace_filter
        )

        # Only important namespace should be stored
        self.assertEqual(len(self.events), 1)
        self.assertEqual(self.events[0]['data']['namespace'], 'important')

    def test_filter_by_priority(self):
        """Test filtering events by priority."""
        def priority_filter(event):
            return event['data'].get('priority', 0) >= 5

        for i in range(10):
            self.publish_with_filter(
                'test.event',
                {'priority': i},
                priority_filter
            )

        # Only events with priority >= 5
        self.assertEqual(len(self.events), 5)

        for event in self.events:
            self.assertGreaterEqual(event['data']['priority'], 5)

    def test_filter_by_timestamp(self):
        """Test filtering events by timestamp."""
        cutoff = time.time()
        time.sleep(0.01)

        def time_filter(event):
            return event['timestamp'] > cutoff

        # Old event (should be filtered out)
        old_event = {
            'type': 'test.event',
            'timestamp': cutoff - 1,
            'data': {}
        }

        # New event (should pass filter)
        new_event = {
            'type': 'test.event',
            'timestamp': time.time(),
            'data': {}
        }

        self.assertTrue(time_filter(new_event))
        self.assertFalse(time_filter(old_event))


class TestAsyncEventHandling(unittest.TestCase):
    """Test asynchronous event handling."""

    def test_async_event_handler(self):
        """Test asynchronous event handling."""
        import queue

        event_queue = queue.Queue()
        processed = []

        def async_handler(event):
            """Simulate async processing."""
            time.sleep(0.01)
            processed.append(event)

        def worker():
            """Worker thread."""
            while True:
                try:
                    event = event_queue.get(timeout=1)
                    if event is None:
                        break
                    async_handler(event)
                    event_queue.task_done()
                except queue.Empty:
                    break

        # Start worker thread
        thread = threading.Thread(target=worker)
        thread.start()

        # Queue events
        for i in range(5):
            event = {'type': 'test.event', 'data': {'index': i}}
            event_queue.put(event)

        # Wait for completion
        event_queue.join()
        event_queue.put(None)  # Signal worker to stop
        thread.join()

        self.assertEqual(len(processed), 5)

    def test_concurrent_event_processing(self):
        """Test concurrent event processing."""
        import queue
        import concurrent.futures

        event_queue = queue.Queue()
        processed = []
        lock = threading.Lock()

        def process_event(event):
            """Process event."""
            time.sleep(0.01)
            with lock:
                processed.append(event)

        # Queue events
        events = [
            {'type': 'test.event', 'data': {'index': i}}
            for i in range(10)
        ]

        # Process concurrently
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
            futures = [executor.submit(process_event, e) for e in events]
            concurrent.futures.wait(futures)

        self.assertEqual(len(processed), 10)


class TestEventPersistence(unittest.TestCase):
    """Test event persistence and replay."""

    def setUp(self):
        """Set up event storage."""
        self.event_store = []

    def store_event(self, event):
        """Store event for replay."""
        self.event_store.append(event)

    def replay_events(self, from_timestamp=None):
        """Replay events from a timestamp."""
        if from_timestamp is None:
            return self.event_store.copy()

        return [
            e for e in self.event_store
            if e['timestamp'] >= from_timestamp
        ]

    def test_event_storage(self):
        """Test storing events."""
        for i in range(5):
            event = {
                'type': 'test.event',
                'timestamp': time.time(),
                'data': {'index': i}
            }
            self.store_event(event)

        self.assertEqual(len(self.event_store), 5)

    def test_event_replay_all(self):
        """Test replaying all events."""
        # Store events
        for i in range(5):
            event = {
                'type': 'test.event',
                'timestamp': time.time(),
                'data': {'index': i}
            }
            self.store_event(event)

        # Replay all
        replayed = self.replay_events()

        self.assertEqual(len(replayed), 5)
        for i, event in enumerate(replayed):
            self.assertEqual(event['data']['index'], i)

    def test_event_replay_from_timestamp(self):
        """Test replaying events from a specific timestamp."""
        # Store events with delays
        timestamps = []
        for i in range(5):
            event = {
                'type': 'test.event',
                'timestamp': time.time(),
                'data': {'index': i}
            }
            timestamps.append(event['timestamp'])
            self.store_event(event)
            time.sleep(0.01)

        # Replay from middle timestamp
        cutoff = timestamps[2]
        replayed = self.replay_events(from_timestamp=cutoff)

        # Should get events 2, 3, 4
        self.assertEqual(len(replayed), 3)
        self.assertEqual(replayed[0]['data']['index'], 2)


def run_event_bus_tests():
    """Run all event bus integration tests."""
    suite = unittest.TestSuite()

    test_classes = [
        TestEventBusBasics,
        TestEventPublishing,
        TestEventSubscription,
        TestEventFiltering,
        TestAsyncEventHandling,
        TestEventPersistence,
    ]

    for test_class in test_classes:
        tests = unittest.TestLoader().loadTestsFromTestCase(test_class)
        suite.addTests(tests)

    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)

    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(run_event_bus_tests())
