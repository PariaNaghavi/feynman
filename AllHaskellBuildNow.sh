#!/bin/bash
for file in /Users/paria/Desktop/feynman/*.hs; do
	
runhaskell $file.hs configure --ghc

done
