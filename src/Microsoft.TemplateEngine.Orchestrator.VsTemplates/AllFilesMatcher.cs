using System;
using Microsoft.TemplateEngine.Runner;

namespace Microsoft.TemplateEngine.Orchestrator.VsTemplates
{
    internal class AllFilesMatcher : IPathMatcher
    {
        public string Pattern => null;

        public bool IsMatch(string path)
        {
            return true;
        }
    }
}