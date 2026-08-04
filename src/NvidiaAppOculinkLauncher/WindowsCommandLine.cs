using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;

namespace NvidiaAppOculinkLauncher
{
    internal static class WindowsCommandLine
    {
        internal static string JoinArguments(IEnumerable<string> arguments)
        {
            return string.Join(" ", arguments.Select(QuoteArgument));
        }

        internal static string QuoteArgument(string value)
        {
            if (value == null)
            {
                throw new ArgumentNullException(nameof(value));
            }
            if (value.IndexOf('\0') >= 0)
            {
                throw new ArgumentException("Arguments cannot contain NUL.", nameof(value));
            }
            if (value.Length > 0 &&
                value.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0)
            {
                return value;
            }

            var result = new StringBuilder(value.Length + 2);
            result.Append('"');
            int backslashes = 0;
            foreach (char character in value)
            {
                if (character == '\\')
                {
                    backslashes++;
                    continue;
                }
                if (character == '"')
                {
                    result.Append('\\', backslashes * 2 + 1);
                    result.Append('"');
                    backslashes = 0;
                    continue;
                }
                result.Append('\\', backslashes);
                backslashes = 0;
                result.Append(character);
            }
            result.Append('\\', backslashes * 2);
            result.Append('"');
            return result.ToString();
        }
    }
}
