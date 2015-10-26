﻿// Copyright (c) .NET Foundation. All rights reserved.
// Licensed under the Apache License, Version 2.0. See License.txt in the project root for license information.

using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using NuGet.Packaging;
using NuGet.Versioning;
using Xunit;

namespace NuGetGallery.Packaging
{
    public class NupkgRewriterFacts
    {
        [Fact]
        public static void CanRewriteTheNuspecInANupkg()
        {
            var packageStream = CreateTestPackageStream();

            // Act
            NupkgRewriter.RewriteNupkgManifest(packageStream,
                    new List<Action<ManifestEdit>>
                    {
                        metadata => { metadata.Authors = "Me and You"; },
                        metadata => { metadata.Tags = "Peas In A Pod"; }
                    });

            // Assert
            using (var nupkg = new PackageReader(packageStream, leaveStreamOpen: false))
            {
                var nuspec = nupkg.GetNuspecReader();

                Assert.Equal("TestPackage", nuspec.GetId());
                Assert.Equal(NuGetVersion.Parse("0.0.0.1"), nuspec.GetVersion());
                Assert.Equal("Me and You", nuspec.GetMetadata().First(kvp => kvp.Key == "authors").Value);
                Assert.Equal("Peas In A Pod", nuspec.GetMetadata().First(kvp => kvp.Key == "tags").Value);
            }
        }

        private static Stream CreateTestPackageStream()
        {
            var packageStream = new MemoryStream();
            using (var packageArchive = new ZipArchive(packageStream, ZipArchiveMode.Create, true))
            {
                var nuspecEntry = packageArchive.CreateEntry("TestPackage.nuspec", CompressionLevel.Fastest);
                using (var streamWriter = new StreamWriter(nuspecEntry.Open()))
                {
                    streamWriter.WriteLine(@"<?xml version=""1.0""?>
                    <package xmlns=""http://schemas.microsoft.com/packaging/2011/08/nuspec.xsd"">
                      <metadata>
                        <id>TestPackage</id>
                        <version>0.0.0.1</version>
                        <title>Package A</title>
                        <authors>ownera, ownerb</authors>
                        <owners>ownera, ownerb</owners>
                        <requireLicenseAcceptance>false</requireLicenseAcceptance>
                        <description>package A description.</description>
                        <language>en-US</language>
                        <dependencies />
                      </metadata>
                    </package>");
                }

                packageArchive.CreateEntry("content\\HelloWorld.cs", CompressionLevel.Fastest);
            }

            packageStream.Position = 0;

            return packageStream;
        }
    }
}
