"""Home Scanner upload endpoint for floor plans sent from the iPhone app."""

from __future__ import annotations

from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.typing import ConfigType

from .const import DOMAIN
from .http import async_register

__all__ = ["async_setup", "async_setup_entry", "async_unload_entry"]


async def async_setup(hass: HomeAssistant, config: ConfigType) -> bool:
    """Set up from configuration.yaml (`home_scanner:`)."""
    hass.data.setdefault(DOMAIN, {})
    if DOMAIN in config:
        async_register(hass)
    return True


async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    """Set up from the UI."""
    async_register(hass)
    return True


async def async_unload_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    """Leave the HTTP views in place. A restart removes them with the integration."""
    return True
