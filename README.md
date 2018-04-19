# docker-manifest-sh
A shell implementation for "docker manifest" cmd
-----------------
This script implements exactly __SAME__ features as the same command in docker.

## Why another wheel?

Multi-arch docker images is awesome, and very useful for CI/CD.
I'm doing a lot of work simultaneously on both X86-64 and arm in daily work, and adding code to check architecture and pull/push images with certain suffix (x86_64, arm64, arm) just boring, ugly and easy to run into error because of a tiny typo.

About a year ago, Christy Norman from IBM created a [PR](https://github.com/docker/cli/pull/138) to support multi-arch docker images through manifest.
There is also another [standalone tool](https://github.com/estesp/manifest-tool) created by Phil Estes.

The PR has a lot of changes, and takes about 1 year to get merged by upstream.
The standalone tool is great, but you have to build the binary, and then create yaml file to push manifest. Yes, `from-args` provides another option but it is not that convenient.

So that's why I tried to create another wheel to do the same job.
By using bash script, it can run on almost every linux distros without any build steps. And it has very limited dependencies:
  * curl
  * jq

All you need to do is download and use it.

## So what about now？
As the PR has been merged, and included in docker 18.02 release, this script can be retired.

If you're using latest docker CLI, or build by your own, you don't need this script.
But for people who uses the distros, Ubuntu/CentOS/Fedora/Debian/..., the docker CLI is not updated. So you can try this script instead of build latest binaries.

Also the script can help people who wants to know what actually happens to create/push/pull manifests/image blobs, how to use docker's HTTP API. I comment it as much as possible. Hope this help you.
