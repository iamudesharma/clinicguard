"""LLM wrapper that fails over between providers on HTTP 429 (rate limit).

Primary provider serves every request; on a 429 the request is retried against
the fallback provider immediately, and the primary is put into a cooldown so
subsequent turns don't hammer a rate-limited provider. After the cooldown the
primary is tried again.

Usage:
    from plugins.fallback_llm import FallbackLLM

    llm = FallbackLLM(
        primary=groq.LLM(model="llama-3.3-70b-versatile"),
        fallback=openai.LLM(base_url="https://openrouter.ai/api/v1", ...),
        cooldown_seconds=300,
    )
"""

from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import replace
from typing import Any

from livekit.agents import llm, utils
from livekit.agents._exceptions import APIStatusError
from livekit.agents.llm.llm import DEFAULT_API_CONNECT_OPTIONS
from livekit.agents.types import NOT_GIVEN, NotGivenOr

logger = logging.getLogger("fallback-llm")

RATE_LIMIT_STATUS = 429


class FallbackLLM(llm.LLM):
    def __init__(
        self,
        *,
        primary: llm.LLM,
        fallback: llm.LLM,
        cooldown_seconds: float = 300.0,
    ) -> None:
        super().__init__()
        self._primary = primary
        self._fallback = fallback
        self._cooldown_seconds = cooldown_seconds
        self._cooldown_until = 0.0
        self._active = primary

        # forward provider metrics/errors up through the wrapper so the session
        # observability sees both providers
        for provider in (primary, fallback):
            provider.on("metrics_collected", self._forward_metrics)
            provider.on("error", self._forward_error)

    def _forward_metrics(self, *args: Any, **kwargs: Any) -> None:
        self.emit("metrics_collected", *args, **kwargs)

    def _forward_error(self, *args: Any, **kwargs: Any) -> None:
        self.emit("error", *args, **kwargs)

    @property
    def model(self) -> str:
        return self._active.model

    @property
    def provider(self) -> str:
        return self._active.provider

    @property
    def active_provider(self) -> str:
        return self._active.provider

    def _choose_provider(self) -> llm.LLM:
        now = time.monotonic()
        if self._cooldown_until > now:
            return self._fallback
        return self._primary

    def _mark_rate_limited(self) -> None:
        self._cooldown_until = time.monotonic() + self._cooldown_seconds
        logger.warning(
            "primary LLM (%s) rate limited; using fallback (%s) for %ss",
            self._primary.provider,
            self._fallback.provider,
            self._cooldown_seconds,
        )

    def chat(
        self,
        *,
        chat_ctx: llm.ChatContext,
        tools: list[llm.Tool] | None = None,
        conn_options: utils.APIConnectOptions = DEFAULT_API_CONNECT_OPTIONS,
        parallel_tool_calls: NotGivenOr[bool] = NOT_GIVEN,
        tool_choice: NotGivenOr[llm.ToolChoice] = NOT_GIVEN,
        extra_kwargs: NotGivenOr[dict[str, Any]] = NOT_GIVEN,
    ) -> llm.LLMStream:
        return FallbackLLMStream(
            llm=self,
            chat_ctx=chat_ctx,
            tools=tools or [],
            conn_options=conn_options,
            primary=self._primary,
            fallback=self._fallback,
            parallel_tool_calls=parallel_tool_calls,
            tool_choice=tool_choice,
            extra_kwargs=extra_kwargs,
        )

    async def aclose(self) -> None:
        await super().aclose()
        for provider in (self._primary, self._fallback):
            provider.off("metrics_collected", self._forward_metrics)
            provider.off("error", self._forward_error)
            await provider.aclose()


class FallbackLLMStream(llm.LLMStream):
    def __init__(
        self,
        *,
        llm: FallbackLLM,
        chat_ctx: llm.ChatContext,
        tools: list[llm.Tool],
        conn_options: utils.APIConnectOptions,
        primary: llm.LLM,
        fallback: llm.LLM,
        parallel_tool_calls: NotGivenOr[bool],
        tool_choice: NotGivenOr[llm.ToolChoice],
        extra_kwargs: NotGivenOr[dict[str, Any]],
    ) -> None:
        super().__init__(llm=llm, chat_ctx=chat_ctx, tools=tools, conn_options=conn_options)
        self._primary = primary
        self._fallback = fallback
        self._parallel_tool_calls = parallel_tool_calls
        self._tool_choice = tool_choice
        self._extra_kwargs = extra_kwargs

    def _new_provider_stream(self, provider: llm.LLM) -> llm.LLMStream:
        # zero-retry at the provider level: the provider's own stream would retry a
        # 429 internally and surface as APIConnectionError; we want the raw 429 so
        # the failover here is deterministic.
        zero_retry = replace(self._conn_options, max_retry=0)
        return provider.chat(
            chat_ctx=self.chat_ctx,
            tools=self.tools,
            conn_options=zero_retry,
            parallel_tool_calls=self._parallel_tool_calls,
            tool_choice=self._tool_choice,
            extra_kwargs=self._extra_kwargs,
        )

    async def _run(self) -> None:
        primary = self._llm._choose_provider()  # type: ignore[attr-defined]
        providers = [(primary, "primary"), (self._fallback, "fallback")] if primary is self._primary else [(self._fallback, "fallback")]
        if len(providers) == 1:
            # cooldown active: only the fallback is eligible this request
            await self._forward_stream(self._fallback, "fallback")
            return

        try:
            await self._forward_stream(primary, "primary")
        except APIStatusError as e:
            if e.status_code != RATE_LIMIT_STATUS:
                raise
            self._llm._mark_rate_limited()  # type: ignore[attr-defined]
            await self._forward_stream(self._fallback, "fallback")

    async def _forward_stream(self, provider: llm.LLM, label: str) -> None:
        logger.info("LLM request via %s (%s)", label, provider.provider)
        stream = self._new_provider_stream(provider)
        try:
            async for chunk in stream:
                self._event_ch.send_nowait(chunk)
        finally:
            await stream.aclose()
