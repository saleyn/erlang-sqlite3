@echo off
set PATH=c:\Program Files (x86)\erl10.4\bin;%PATH%
call "C:\Program Files (x86)\Microsoft Visual Studio\2019\Community\VC\Auxiliary\Build\vcvars32.bat"

nmake /f Makefile compile
