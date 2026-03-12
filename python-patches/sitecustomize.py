import os


def patch_transformers_serve_offload_dir():
    try:
        import transformers
        from transformers import AutoConfig, AutoProcessor, AutoTokenizer
        from transformers.cli import serve as serve_module
    except Exception:
        return

    serve_class = getattr(serve_module, "Serve", None) or getattr(serve_module, "ServeCommand", None)
    if serve_class is None or getattr(serve_class, "_local_codex_offload_patch_applied", False):
        return

    def _patched_load_model_and_data_processor(self, model_id_and_revision: str):
        import torch

        logger = serve_module.logger
        logger.info(f"Loading {model_id_and_revision}")

        if "@" in model_id_and_revision:
            model_id, revision = model_id_and_revision.split("@", 1)
        else:
            model_id, revision = model_id_and_revision, "main"

        try:
            data_processor = AutoProcessor.from_pretrained(
                model_id,
                revision=revision,
                trust_remote_code=self.trust_remote_code,
            )
        except OSError:
            try:
                data_processor = AutoTokenizer.from_pretrained(
                    model_id,
                    revision=revision,
                    trust_remote_code=self.trust_remote_code,
                )
            except OSError as exc:
                raise OSError("Failed to load processor with `AutoProcessor` and `AutoTokenizer`.") from exc

        dtype = self.dtype if self.dtype in ["auto", None] else getattr(torch, self.dtype)
        quantization_config = self.get_quantization_config()

        common_kwargs = {
            "revision": revision,
            "attn_implementation": self.attn_implementation,
            "dtype": dtype,
            "device_map": self.device,
            "trust_remote_code": self.trust_remote_code,
            "quantization_config": quantization_config,
        }

        config = AutoConfig.from_pretrained(model_id, **common_kwargs)
        architecture = getattr(transformers, config.architectures[0])
        model_kwargs = dict(common_kwargs)
        offload_dir = os.environ.get(
            "LOCAL_CODEX_TRANSFORMERS_OFFLOAD_DIR",
            "/tmp/local-codex-kit/transformers-offload",
        )
        os.makedirs(offload_dir, exist_ok=True)
        model_kwargs["offload_folder"] = offload_dir
        model = architecture.from_pretrained(model_id, **model_kwargs)

        has_default_max_length = (
            model.generation_config.max_new_tokens is None and model.generation_config.max_length == 20
        )
        has_short_max_new_tokens = (
            model.generation_config.max_new_tokens is not None and model.generation_config.max_new_tokens < 1024
        )
        if has_default_max_length or has_short_max_new_tokens:
            model.generation_config.max_new_tokens = 1024

        logger.info(f"Loaded model {model_id_and_revision}")
        return model, data_processor

    serve_class._load_model_and_data_processor = _patched_load_model_and_data_processor
    serve_class._local_codex_offload_patch_applied = True


def get_min_output_tokens():
    try:
        return max(64, int(os.environ.get("LOCAL_CODEX_TRANSFORMERS_MIN_OUTPUT_TOKENS", "1024")))
    except (TypeError, ValueError):
        return 1024


def patch_transformers_serve_response_generation():
    try:
        from transformers.cli import serve as serve_module
    except Exception:
        return

    serve_class = getattr(serve_module, "Serve", None) or getattr(serve_module, "ServeCommand", None)
    if serve_class is None:
        return

    if not getattr(serve_module, "_local_codex_generation_config_patch_applied", False):
        original_create_generation_config = serve_module.create_generation_config_from_req

        def _patched_create_generation_config_from_req(req, model_generation_config, **kwargs):
            generation_config = original_create_generation_config(req, model_generation_config, **kwargs)
            if req.get("max_output_tokens") is None and req.get("max_tokens") is None:
                min_output_tokens = get_min_output_tokens()
                current_max_new_tokens = getattr(generation_config, "max_new_tokens", None)
                if current_max_new_tokens is None or int(current_max_new_tokens) < min_output_tokens:
                    generation_config.max_new_tokens = min_output_tokens
            return generation_config

        serve_module.create_generation_config_from_req = _patched_create_generation_config_from_req
        serve_module._local_codex_generation_config_patch_applied = True

    if getattr(serve_class, "_local_codex_response_patch_applied", False):
        return

    def _patched_generate_response(self, req):
        model_id_and_revision = self.process_model_name(req["model"])
        must_discard_cache = model_id_and_revision != self.last_model
        self.last_model = model_id_and_revision
        model, processor = self.load_model_and_processor(model_id_and_revision)

        if isinstance(req["input"], str):
            inputs = [{"role": "system", "content": req["instructions"]}] if "instructions" in req else []
            inputs.append({"role": "user", "content": req["input"]})
        elif isinstance(req["input"], list):
            if "instructions" in req:
                if req["input"][0]["role"] != "system":
                    inputs = [{"role": "system", "content": req["instructions"]}, *req["input"]]
                else:
                    inputs = req["input"]
                    inputs[0]["content"] = req["instructions"]
            else:
                inputs = req["input"]
        elif isinstance(req["input"], dict):
            inputs = [{"role": "system", "content": req["instructions"]}] if "instructions" in req else []
            inputs.append(req["input"])
        else:
            raise TypeError("inputs should be a list, dict, or str")

        inputs = processor.apply_chat_template(
            inputs, add_generation_prompt=True, return_tensors="pt", return_dict=True
        )["input_ids"]
        inputs = inputs.to(model.device)
        request_id = req.get("previous_response_id", "req_0")

        is_gptoss = "gptoss" in model.config.architectures[0].lower()
        generation_streamer = serve_module.TextIteratorStreamer(
            processor,
            skip_special_tokens=not is_gptoss,
            skip_prompt=True,
        )
        generation_config = serve_module.create_generation_config_from_req(
            req, model_generation_config=model.generation_config
        )

        last_kv_cache = None
        if self.is_continuation(req) and not must_discard_cache:
            seq_len = self.last_kv_cache.get_seq_length()
            if inputs.shape[-1] > seq_len:
                last_kv_cache = self.last_kv_cache

        generation_kwargs = {
            "inputs": inputs,
            "attention_mask": serve_module.torch_ones_like(inputs),
            "streamer": generation_streamer,
            "generation_config": generation_config,
            "return_dict_in_generate": True,
            "past_key_values": last_kv_cache,
        }

        def stream_response(streamer, _request_id):
            filter_reasoning = is_gptoss
            final_channel_marker = "<|channel|>final<|message|>" if is_gptoss else None

            def generate_with_cache(**kwargs):
                generate_output = model.generate(**kwargs)
                self.last_kv_cache = generate_output.past_key_values

            def build_text_delta(sequence_number, content_index, delta):
                return serve_module.ResponseTextDeltaEvent(
                    type="response.output_text.delta",
                    item_id=f"msg_{request_id}",
                    sequence_number=sequence_number,
                    output_index=0,
                    content_index=content_index,
                    delta=delta,
                    logprobs=[],
                )

            thread = serve_module.Thread(target=generate_with_cache, kwargs=generation_kwargs)
            sequence_number = 0
            content_index = 0
            results = ""

            try:
                thread.start()
                created_at = serve_module.time.time()

                response_created = serve_module.ResponseCreatedEvent(
                    type="response.created",
                    sequence_number=sequence_number,
                    response=serve_module.Response(
                        id=f"resp_{request_id}",
                        created_at=created_at,
                        status="queued",
                        model=model_id_and_revision,
                        instructions=req.get("instructions"),
                        text={"format": {"type": "text"}},
                        object="response",
                        tools=[],
                        output=[],
                        parallel_tool_calls=req.get("parallel_tool_calls", False),
                        tool_choice="auto",
                        metadata=req.get("metadata"),
                    ),
                )
                sequence_number += 1
                yield self.chunk_to_sse_element(response_created)

                response_in_progress = serve_module.ResponseInProgressEvent(
                    type="response.in_progress",
                    sequence_number=sequence_number,
                    response=serve_module.Response(
                        id=f"resp_{request_id}",
                        created_at=created_at,
                        status="in_progress",
                        model=model_id_and_revision,
                        instructions=req.get("instructions"),
                        text={"format": {"type": "text"}},
                        object="response",
                        tools=[],
                        output=[],
                        parallel_tool_calls=req.get("parallel_tool_calls", False),
                        tool_choice="auto",
                        metadata=req.get("metadata"),
                    ),
                )
                sequence_number += 1
                yield self.chunk_to_sse_element(response_in_progress)

                response_output_item_added = serve_module.ResponseOutputItemAddedEvent(
                    type="response.output_item.added",
                    sequence_number=sequence_number,
                    output_index=0,
                    item=serve_module.ResponseOutputMessage(
                        id=f"msg_{request_id}", type="message", status="in_progress", role="assistant", content=[]
                    ),
                )
                sequence_number += 1
                yield self.chunk_to_sse_element(response_output_item_added)

                response_content_part_added = serve_module.ResponseContentPartAddedEvent(
                    type="response.content_part.added",
                    item_id=f"msg_{request_id}",
                    sequence_number=sequence_number,
                    output_index=0,
                    content_index=content_index,
                    part=serve_module.ResponseOutputText(type="output_text", text="", annotations=[]),
                )
                sequence_number += 1
                yield self.chunk_to_sse_element(response_content_part_added)

                for result in streamer:
                    if is_gptoss:
                        result = result.removesuffix("<|return|>")

                    if filter_reasoning:
                        results += result
                        if final_channel_marker in results:
                            filter_reasoning = False
                            results = results.split(final_channel_marker, 1)[1]
                            if results:
                                response_output_text_delta = build_text_delta(
                                    sequence_number=sequence_number,
                                    content_index=content_index,
                                    delta=results,
                                )
                                sequence_number += 1
                                yield self.chunk_to_sse_element(response_output_text_delta)
                            continue

                        response_output_text_delta = build_text_delta(
                            sequence_number=sequence_number,
                            content_index=content_index,
                            delta="",
                        )
                        sequence_number += 1
                        yield self.chunk_to_sse_element(response_output_text_delta)
                        continue

                    if result:
                        results += result
                        response_output_text_delta = build_text_delta(
                            sequence_number=sequence_number,
                            content_index=content_index,
                            delta=result,
                        )
                        sequence_number += 1
                        yield self.chunk_to_sse_element(response_output_text_delta)

                if filter_reasoning and final_channel_marker and final_channel_marker in results:
                    results = results.split(final_channel_marker, 1)[1]
                elif filter_reasoning and is_gptoss:
                    results = ""

                response_output_text_done = serve_module.ResponseTextDoneEvent(
                    type="response.output_text.done",
                    item_id=f"msg_{request_id}",
                    sequence_number=sequence_number,
                    output_index=0,
                    content_index=0,
                    text=results,
                    logprobs=[],
                )
                sequence_number += 1
                yield self.chunk_to_sse_element(response_output_text_done)

                response_content_part_done = serve_module.ResponseContentPartDoneEvent(
                    type="response.content_part.done",
                    item_id=f"msg_{request_id}",
                    sequence_number=sequence_number,
                    output_index=0,
                    content_index=content_index,
                    part=serve_module.ResponseOutputText(type="output_text", text=results, annotations=[]),
                )
                sequence_number += 1
                content_index += 1
                yield self.chunk_to_sse_element(response_content_part_done)

                response_output_item_done = serve_module.ResponseOutputItemDoneEvent(
                    type="response.output_item.done",
                    sequence_number=sequence_number,
                    output_index=0,
                    item=serve_module.ResponseOutputMessage(
                        id=f"msg_{request_id}",
                        type="message",
                        status="completed",
                        role="assistant",
                        content=[response_content_part_done.part],
                        annotations=[],
                    ),
                )
                sequence_number += 1
                yield self.chunk_to_sse_element(response_output_item_done)

                response_completed = serve_module.ResponseCompletedEvent(
                    type="response.completed",
                    sequence_number=sequence_number,
                    response=serve_module.Response(
                        id=f"resp_{request_id}",
                        created_at=created_at,
                        status="completed",
                        model=model_id_and_revision,
                        instructions=req.get("instructions"),
                        text={"format": {"type": "text"}},
                        output=[response_output_item_done.item],
                        object="response",
                        tools=[],
                        parallel_tool_calls=req.get("parallel_tool_calls", False),
                        tool_choice="auto",
                        metadata=req.get("metadata"),
                    ),
                )
                sequence_number += 1
                yield self.chunk_to_sse_element(response_completed)
                thread.join()
            except Exception as exc:
                serve_module.logger.error(f"Exception in response generation: {str(exc)}")
                error_event = serve_module.ResponseErrorEvent(
                    type="error",
                    sequence_number=sequence_number,
                    message=str(exc),
                )
                yield self.chunk_to_sse_element(error_event)

        return stream_response(generation_streamer, request_id)

    serve_class.generate_response = _patched_generate_response
    serve_class._local_codex_response_patch_applied = True


patch_transformers_serve_offload_dir()
patch_transformers_serve_response_generation()
