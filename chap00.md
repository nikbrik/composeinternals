# Prelude

## Why to read this book

Jetpack Compose has officially become the new standard for UI development in the Android platform. Even if lots of apps still rely on the View system for their already existing UI, new screens and components are very frequently coded using Compose, so it is becoming an unavoidable technology to learn. My strong suggestion is to dedicate some time to learn about its internals in detail, since that will make you gain powerful knowledgeability and skills to write correct, modern, and efficient Android apps.

In the other hand, if you happen to be interested in other use cases of Jetpack Compose rather than Android, you’ll be happy to know that this book has got you covered also. Jetpack Compose internals is very focused on the compiler and runtime details, making the overall experience very agnostic of the target platform. Having an Android background is not a requirement for reading this book. The book also contains a chapter dedicated to different use cases of the library, which exposes a few really interesting examples over code.

Finally, if you are a curious engineer this might be a great chance to learn something new, and a perfect challenge for you.

## What this book is not about

This book does not aim to replicate the Jetpack Compose official documentation, which is quite good already and the source of truth for anyone starting with it. For that reason, you will not find here any listings or catalogues of all the existing components or APIs that the library provides.

If you are new to Compose, I can recommend a sibling book to have on your desk along this one: [“Practical Jetpack Compose” book by Joe Birch](https://practicaljetpackcompose.com/). Joe’s book is full of interesting examples and detailed explanations about all the relevant components and APIs available. The book showcases a set of applications to teach you Compose over code.

## Why to write about internals

As an Android developer and over the years, I have grown a feeling of how astoundingly important can become to learn the internals of the platform you work with every day. It is a game changer. Working on this knowledge base regularly helps me to understand what code I want to write, and why. It enables me to write performant code that complies with the platform expectations, and to understand why things work the way they do. To me, this is probably one of the biggest differences between not very experienced and experienced Android developers.

My personal goal as the author of this book is to give you all the tools to achieve a big leap forward on this field.

## Keep the sources close

If you ask me, I’d say that reading sources is one of the most convenient skills we can grow as software developers, no matter who wrote them. I strongly recommend anyone reading this book to keep the sources as close as possible while reading it, and explore even further. You can find everything in [cs.android.com](https://cs.android.com/). Sources are also indexed in Android Studio, so you should be able to navigate those. Having a playground project with Compose around can also be desirable.

## Code snippets and examples

One of the things we will learn in this book is that Jetpack Compose can be used not only to represent UI trees but essentially any large call graphs with any types of nodes. However, many of the code snippets and examples you’ll find in this book will be UI oriented for an easier mental mapping, since that is what most developers are used to at this point.

------------------------------------------------------------------------

Welcome to Jetpack Compose Internals. Grab a coffee, have a seat, and enjoy the reading.

Jorge.