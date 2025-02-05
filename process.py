#!/usr/bin/env python3
"""
Static Library Merger - Merges multiple static libraries into a single archive.
"""

import argparse
import logging
import platform
import subprocess
import sys
import tempfile
from pathlib import Path

class StaticLibraryMerger:
    def __init__(self, output_lib, llvm_install_dir):
        self.system = platform.system()
        self.output_lib = Path(output_lib).resolve()
        self.llvm_install_dir = Path(llvm_install_dir).resolve()

        self.tmpdir = None
        self.logger = logging.getLogger(self.__class__.__name__)
        
        # Platform configuration
        self.obj_ext = self._get_obj_ext()
        self.ar_cmd = self._get_ar_command()

    def _get_obj_ext(self):
        """Get platform-specific object file extension"""
        if self.system == 'Windows':
            return '.obj'
        return '.o'

    def _get_ar_command(self):
        """Get platform-specific ar command parameters"""
        if self.system == 'Darwin':
            return ['ar', '-qcT']  # macOS
        return ['ar', '-qcs']      # Linux/Windows

    def _convert_msys_path(self, path):
        """Convert Windows path to MSYS2 path using cygpath"""
        try:
            result = subprocess.run(
                ['cygpath', '-u', str(path)],
                check=True,
                capture_output=True,
                text=True
            )
            return result.stdout.strip()
        except subprocess.CalledProcessError as e:
            self.logger.error(f"Path conversion failed: {e.stderr.strip()}")
            raise

    def _run_command(self, cmd, cwd=None):
        """Execute a command with MSYS2 path conversion if needed"""
        # Convert paths for MSYS2 environment
        self.logger.debug(f"Executing: {' '.join(cmd)}")
        try:
            subprocess.run(cmd, cwd=cwd, check=True)
        except subprocess.CalledProcessError as e:
            self.logger.error(f"Command failed: {e}")
            raise

    def extract_llvm_objects(self):
        """Extract object files from LLVM static libraries"""
        self.logger.info("Extracting LLVM objects...")
        
        for lib_path in self.llvm_install_dir.glob('lib/*.a'):
            if lib_path.name.endswith('.dll.a'):
                continue
            
            lib_name = lib_path.stem
            output_dir = self.tmpdir / lib_name
            output_dir.mkdir(parents=True, exist_ok=True)
            
            self.logger.debug(f"Extracting {lib_path} to {output_dir}")
            try:
                self._run_command(['ar', 'x', str(lib_path)], cwd=output_dir)
            except Exception:
                self.logger.error(f"Failed to extract {lib_path}")
                raise

    def _find_std_library(self):
        """Find platform-specific standard library"""
        if self.system == 'Linux':
            return self._find_linux_std_lib()
        if self.system == 'Windows':
            return self._find_windows_std_lib()
        raise RuntimeError(f"Unsupported system: {self.system}")

    def _find_linux_std_lib(self):
        """Find libstdc++.a on Linux"""
        for path in Path('/usr/lib/gcc').rglob('libstdc++.a'):
            return path
        raise FileNotFoundError("libstdc++.a not found in /usr/lib/gcc")

    def _find_windows_std_lib(self):
        """Find libstdc++.a on Windows with MSYS2 support"""
        # Try multiple possible locations
        search_paths = [
            Path('/mingw64/lib/libstdc++.a'),
        ]

        for lib_path in search_paths:
            if lib_path.exists():
                self.logger.debug(f"Found libstdc++.a at {lib_path}")
                return lib_path

        raise FileNotFoundError(
            "libstdc++.a not found in standard locations.\n"
            "Try installing it with: pacman -S mingw-w64-x86_64-gcc"
        )
    
    def extract_std_objects(self):
        """Extract standard library objects"""
        if self.system == 'Darwin':
            return # dynamic link libc++ for macOS

        try:
            std_lib = self._find_std_library()
        except Exception as e:
            self.logger.warning(str(e))
            return

        self.logger.info(f"Extracting standard library: {std_lib}")
        lib_name = std_lib.stem
        output_dir = self.tmpdir / lib_name
        output_dir.mkdir(parents=True, exist_ok=True)
        
        try:
            self._run_command(['ar', 'x', str(std_lib)], cwd=output_dir)
        except Exception:
            self.logger.error(f"Failed to extract {std_lib}")
            raise

    def merge_objects(self):
        """Merge all object files into final library"""
        self.logger.info("Merging objects into final library...")
        
        # Remove existing library
        if self.output_lib.exists():
            self.output_lib.unlink()

        # Collect all object files
        obj_files = list(self.tmpdir.rglob(f'*{self.obj_ext}'))
        if not obj_files:
            self.logger.error("No object files found for merging")
            raise RuntimeError("No objects to merge")
            
        self.logger.info(f"Merging {len(obj_files)} object files")

        # Handle different argument passing methods
        if self.system == 'Darwin':
            self._merge_direct(obj_files)
        else:
            self._merge_with_filelist(obj_files)

        # Run ranlib after archive creation
        self._run_ranlib()

    def _merge_direct(self, obj_files):
        """Directly pass objects to ar command (macOS)"""
        # Convert paths for macOS if needed
        cmd = self.ar_cmd + [str(self.output_lib)] 
        cmd += [str(p) for p in obj_files]
        self._run_command(cmd)

    def _merge_with_filelist(self, obj_files):
        """Use file list with path conversion for Windows/Linux"""
        with tempfile.NamedTemporaryFile(mode='w+') as tmpfile:
            content = '\n'.join(str(p) for p in obj_files)
            
            tmpfile.write(content)
            tmpfile.flush()
            
            # Use relative path for file list
            file_arg = f'@{tmpfile.name}'
            cmd = self.ar_cmd + [str(self.output_lib), file_arg]
            self._run_command(cmd)

    def _run_ranlib(self):
        """Execute ranlib if needed"""
        self.logger.debug("Running ranlib")
        self._run_command(['ranlib', str(self.output_lib)])

    def merge_libraries(self):
        """Main merging workflow"""
        with tempfile.TemporaryDirectory() as tmpdir_win:
            # Convert temporary directory path for MSYS2 on Windows
            if self.system == 'Windows':
                tmpdir = self._convert_msys_path(tmpdir_win)
            else:
                tmpdir = tmpdir_win
            self.tmpdir = Path(tmpdir)
            self.logger.info(f"Using temporary directory: {self.tmpdir}")

            try:
                self.extract_llvm_objects()
                self.extract_std_objects()
                self.merge_objects()
            except Exception as e:
                self.logger.error(f"Merging failed: {e}")
                raise

def configure_logging(verbose=False):
    """Configure logging system"""
    level = logging.DEBUG if verbose else logging.INFO
    logging.basicConfig(
        format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
        level=level
    )

def main():
    parser = argparse.ArgumentParser(
        description='Merge static libraries into single archive')
    parser.add_argument('-o', '--output', required=True,
                        help='Output library path')
    parser.add_argument('--llvm-install-dir', required=True,
                        help='LLVM installation directory')
    parser.add_argument('-v', '--verbose', action='store_true',
                        help='Enable verbose output')
    
    args = parser.parse_args()

    try:
        configure_logging(args.verbose)
        merger = StaticLibraryMerger(args.output, args.llvm_install_dir)
        merger.merge_libraries()
        logging.info(f"Successfully created library: {args.output}")
    except Exception as e:
        logging.error(f"Fatal error: {e}")
        sys.exit(1)

if __name__ == '__main__':
    main()
