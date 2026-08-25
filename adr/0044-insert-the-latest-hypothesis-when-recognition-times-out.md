# Insert the latest hypothesis when recognition times out

If final recognition has not completed when the watchdog fires, Poptart will insert the latest nonempty, usable incremental recognition hypothesis. It will skip Cleanup, label the outcome as a recognition fallback in the Indicator and Dictation Record, and discard the captured audio afterward. Poptart will not present the hypothesis as a finalized Raw Transcript. If recognition produced no usable text, Poptart inserts nothing and presents a clear failure state.
