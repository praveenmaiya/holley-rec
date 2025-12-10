#!/usr/bin/env python3
"""
Universal Metaflow Remote Runner for Holley.

Executes Python scripts on Kubernetes via Metaflow.
Based on holley-rec-chatgpt/gemini pattern.

Usage:
    python flows/metaflow_runner.py run --script src/bandit_click_holley.py --with kubernetes
"""

from metaflow import FlowSpec, step, Parameter, kubernetes, IncludeFile
import subprocess
import sys
import os


class CloudScriptRunner(FlowSpec):
    """
    Universal Remote Runner.
    Acts as a "Cloud Shell" to execute any Python script on Kubernetes.
    """

    # 1. What to run - use IncludeFile to embed script content in the flow
    script_content = IncludeFile('script', help="Path to the .py file to execute")
    script_args = Parameter('args', default="", help="Arguments to pass to the script (as a string)")

    # 2. Environment Setup
    pip_packages = Parameter('pip', default="", help="Comma-separated list of pip packages to install")
    req_file = Parameter('requirements', default="", help="Path to requirements.txt")

    # 3. Cloud Resources
    cpu = Parameter('cpu', default=1)
    memory = Parameter('memory', default=2048)  # 2GB default for TensorFlow

    @kubernetes(cpu=1, memory=2048, service_account="ksa-metaflow")
    @step
    def start(self):
        print("Cloud Environment Provisioned!")
        print(f"Node: {os.uname().nodename}")
        print(f"Working Directory: {os.getcwd()}")

        # --- A. Dependency Management ---
        packages = []
        if self.pip_packages:
            packages.extend(self.pip_packages.split(','))

        if self.req_file and os.path.exists(self.req_file):
            print(f"Installing dependencies from {self.req_file}...")
            subprocess.check_call([sys.executable, "-m", "pip", "install", "-r", self.req_file])

        if packages:
            print(f"Installing packages: {packages}")
            subprocess.check_call([sys.executable, "-m", "pip", "install"] + packages)

        # --- B. Execution ---
        # Write the script content to a temp file and execute it
        temp_script = "/tmp/remote_script.py"
        with open(temp_script, 'w') as f:
            f.write(self.script_content)

        print(f"Executing embedded script with args: {self.script_args}")
        sys.stdout.flush()

        try:
            args = self.script_args.split() if self.script_args else []
            cmd = [sys.executable, "-u", temp_script] + args

            # Capture output in real-time
            with subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                bufsize=1,
                universal_newlines=True
            ) as p:
                for line in p.stdout:
                    print(f"[REMOTE] {line}", end='')

            if p.returncode != 0:
                raise Exception(f"Script failed with exit code {p.returncode}")

        except Exception as e:
            print(f"Critical Failure: {e}")
            raise e

        self.next(self.end)

    @step
    def end(self):
        print("Cloud execution complete.")


if __name__ == '__main__':
    CloudScriptRunner()
