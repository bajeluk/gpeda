#! /usr/bin/env python
# -*- coding: utf-8 -*-

"""Various tools. 

"""
from __future__ import absolute_import

import os, sys, time
import numpy as np
import warnings

def print_done(message='  done'):
    print message, '(' + time.asctime() + ').'

def equals_approximately(a, b, eps=1e-12):
    if a < 0:
        a, b = -1 * a, -1 * b
    return a - eps < b < a + eps or (1 - eps) * a < b < (1 + eps) * a
 
def prepend_to_file(filename, lines, maxlines=1000, warn_message=None):
    """"prepend lines the tex-command filename """
    try:
        lines_to_append = list(open(filename, 'r'))
    except IOError:
        lines_to_append = []
    f = open(filename, 'w')
    for line in lines:
        f.write(line + '\n')
    for i, line in enumerate(lines_to_append):
        f.write(line)
        if i > maxlines:
            print warn_message
            break
    f.close()
        
def truncate_latex_command_file(filename, keeplines=200):
    """truncate file but keep in good latex shape"""
    open(filename, 'a').close()
    lines = list(open(filename, 'r'))
    f = open(filename, 'w')
    for i, line in enumerate(lines):
        if i > keeplines and line.startswith('\providecommand'):
            break
        f.write(line)
    f.close()
    
def strip_pathname(name):
    """remove ../ and ./ and leading/trainling blanks and path separators from input string ``name``"""
    return name.replace('..' + os.sep, '').replace('.' + os.sep, '').strip().strip(os.sep)

def strip_pathname2(name):
    """remove ../ and ./ and leading/trainling blanks and path separators from input string ``name``
    and keep only the last two parts of the path"""
    return os.sep.join(name.replace('..' + os.sep, '').replace('.' + os.sep, '').strip().strip(os.sep).split(os.sep)[-2:])

def str_to_latex(string):
    """do replacements in ``string`` such that it most likely compiles with latex """
    return string.replace('\\', r'\textbackslash{}').replace('_', '\\_').replace(r'^', r'\^\,').replace(r'%', r'\%').replace(r'~', r'\ensuremath{\sim}').replace(r'#', r'\#')
                    
                    