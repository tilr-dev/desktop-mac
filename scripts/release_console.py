"""Readable release results in terminals; plain text in redirected logs."""
import argparse
import os
import sys


def colored(message, color, stream):
    if stream.isatty() and 'NO_COLOR' not in os.environ and os.environ.get('TERM') != 'dumb':
        return f'\033[1;{color}m{message}\033[0m'
    return message


def success(message):
    print(colored(message, 32, sys.stdout), flush=True)


def failure(message):
    print(colored(message, 31, sys.stderr), file=sys.stderr, flush=True)


class ArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        failure(f'{self.prog}: error: {message}')
        raise SystemExit(2)
