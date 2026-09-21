#!/usr/bin/env python3
"""Run the pinned MLX trainer on local data/models with remote code disabled."""
import os
from pathlib import Path
from types import SimpleNamespace
from functools import partial

os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['TRANSFORMERS_OFFLINE'] = '1'

from transformers import AutoTokenizer
from mlx_lm import lora
from mlx_lm.tuner.datasets import load_dataset


def main():
    parser = lora.build_parser()
    parser.add_argument('--check-only', action='store_true', help='validate chat masking and sequence lengths without training')
    values = vars(parser.parse_args())
    config = {}
    if values.get('config'):
        with open(values['config']) as source:
            config = lora.yaml.safe_load(source)
    args = SimpleNamespace(**{**lora.CONFIG_DEFAULTS, **config,
                              **{k:v for k,v in values.items() if v is not None}})
    args.trust_remote_code = False
    if not Path(args.model).is_dir() or not all((Path(args.data)/f'{s}.jsonl').is_file() for s in ('train','valid','test')):
        parser.error('existing local model and train/valid/test files required')
    if args.report_to is not None or not args.mask_prompt or args.fine_tune_type != 'lora' or args.iters < 1:
        parser.error('this recipe requires masked LoRA training, positive iterations, and no reporting service')
    model, _ = lora.load(args.model, tokenizer_config={'trust_remote_code': False})
    tokenizer = AutoTokenizer.from_pretrained(args.model, local_files_only=True, trust_remote_code=False)
    tokenizer.apply_chat_template = partial(tokenizer.apply_chat_template, enable_thinking=False)
    train, valid, test = load_dataset(args, tokenizer)
    longest = 0
    for dataset in (train, valid, test):
        for index in range(len(dataset)):
            record = dataset[index]
            tokens, offset = dataset.process(record)
            prefix = tokenizer.apply_chat_template(record['messages'][:-1], add_generation_prompt=True,
                                                    enable_thinking=False, return_dict=False)
            if tokens[:offset] != prefix or offset >= len(tokens) or len(tokens) > args.max_seq_length:
                raise ValueError('training prefix/mask differs from non-thinking inference, or sequence would be truncated')
            longest = max(longest, len(tokens))
    print(f'Validated {len(train)}/{len(valid)}/{len(test)} records; longest sequence {longest} tokens.', flush=True)
    if args.check_only:
        return
    if not args.train:
        parser.error('--train is required')
    if Path(args.adapter_path).exists():
        parser.error('adapter path already exists; choose a fresh directory')
    lora.np.random.seed(args.seed)
    lora.train_model(args, model, train, valid)
    if args.test:
        lora.evaluate_model(args, model, test)


if __name__ == '__main__':
    main()
