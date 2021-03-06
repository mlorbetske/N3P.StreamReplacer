﻿using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.TemplateEngine.Abstractions;
using Microsoft.TemplateEngine.Core;
using Microsoft.TemplateEngine.Runner;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;

namespace Microsoft.TemplateEngine.Orchestrator.RunnableProjects
{
    public class RunnableProjectGenerator : IGenerator
    {
        public string Name => "Runnable Project";

        public Task Create(ITemplate template, IParameterSet parameters)
        {
            RunnableProjectTemplate tmplt = (RunnableProjectTemplate)template;

            RunnableProjectOrchestrator o = new RunnableProjectOrchestrator();
            GlobalRunSpec configRunSpec = new GlobalRunSpec(new FileSource(), tmplt.ConfigFile.Parent, parameters, tmplt.Config.Config, tmplt.Config.Special);
            IOperationProvider[] providers = configRunSpec.Operations.ToArray();
            
            foreach(KeyValuePair<IPathMatcher, IRunSpec> special in configRunSpec.Special)
            {
                if(special.Key.IsMatch(".netnew.json"))
                {
                    providers = special.Value.GetOperations(providers).ToArray();
                    break;
                }
            }

            IRunnableProjectConfig m = tmplt.Config.ReprocessWithParameters(parameters, configRunSpec.RootVariableCollection, tmplt.ConfigFile, providers);

            foreach (FileSource source in m.Sources)
            {
                GlobalRunSpec runSpec = new GlobalRunSpec(source, tmplt.ConfigFile.Parent, parameters, m.Config, m.Special);
                string target = Path.Combine(Directory.GetCurrentDirectory(), source.Target);
                o.Run(runSpec, tmplt.ConfigFile.Parent.GetDirectoryAtRelativePath(source.Source), target);
            }

            return Task.FromResult(true);
        }

        public IParameterSet GetParametersForTemplate(ITemplate template)
        {
            RunnableProjectTemplate tmplt = (RunnableProjectTemplate)template;
            return new ParameterSet(tmplt.Config);
        }

        public IEnumerable<ITemplate> GetTemplatesFromSource(IConfiguredTemplateSource source)
        {
            using (IDisposable<ITemplateSourceFolder> root = source.Root)
            {
                return GetTemplatesFromDir(source, root.Value).ToList();
            }
        }

        private JObject ReadConfigModel(ITemplateSourceFile file)
        {
            using (Stream s = file.OpenRead())
            using (TextReader tr = new StreamReader(s, true))
            using (JsonReader r = new JsonTextReader(tr))
            {
                return JObject.Load(r);
            }
        }

        private IEnumerable<ITemplate> GetTemplatesFromDir(IConfiguredTemplateSource source, ITemplateSourceFolder folder)
        {
            foreach (ITemplateSourceEntry entry in folder.Children)
            {
                if (entry.Kind == TemplateSourceEntryKind.File && entry.Name.Equals(".netnew.json", StringComparison.OrdinalIgnoreCase))
                {
                    RunnableProjectTemplate tmp = null;
                    try
                    {
                        ITemplateSourceFile file = (ITemplateSourceFile)entry;
                        JObject srcObject = ReadConfigModel(file);

                        tmp = new RunnableProjectTemplate(srcObject, this, source, file, srcObject.ToObject<IRunnableProjectConfig>(new JsonSerializer
                        {
                            Converters =
                            {
                                new RunnableProjectConfigConverter()
                            }
                        }));
                    }
                    catch
                    {
                    }

                    if (tmp != null)
                    {
                        yield return tmp;
                    }
                }
                else if (entry.Kind == TemplateSourceEntryKind.Folder)
                {
                    foreach (ITemplate template in GetTemplatesFromDir(source, (ITemplateSourceFolder)entry))
                    {
                        yield return template;
                    }
                }
            }
        }

        public bool TryGetTemplateFromSource(IConfiguredTemplateSource target, string name, out ITemplate template)
        {
            template = GetTemplatesFromSource(target).FirstOrDefault(x => string.Equals(x.Name, name, StringComparison.OrdinalIgnoreCase));
            return template != null;
        }

        internal class ParameterSet : IParameterSet
        {
            private readonly IDictionary<string, ITemplateParameter> _parameters = new Dictionary<string, ITemplateParameter>(StringComparer.OrdinalIgnoreCase);

            public ParameterSet(IRunnableProjectConfig config)
            {
                foreach(KeyValuePair<string, Parameter> p in config.Parameters)
                {
                    p.Value.Name = p.Key;
                    _parameters[p.Key] = p.Value;
                }
            }

            public IEnumerable<ITemplateParameter> Parameters => _parameters.Values;

            public IDictionary<ITemplateParameter, string> ParameterValues { get; } = new Dictionary<ITemplateParameter, string>();

            public IEnumerable<string> RequiredBrokerCapabilities => Enumerable.Empty<string>();

            public void AddParameter(ITemplateParameter param)
            {
                _parameters[param.Name] = param;
            }

            public bool TryGetParameter(string name, out ITemplateParameter parameter)
            {
                if (_parameters.TryGetValue(name, out parameter))
                {
                    return true;
                }

                parameter = new Parameter
                {
                    Name = name,
                    Requirement = TemplateParameterPriority.Optional,
                    IsVariable = true,
                    Type = "string"
                };

                return true;
            }
        }
    }
}
